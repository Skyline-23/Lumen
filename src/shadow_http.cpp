/**
 * @file src/shadow_http.cpp
 * @brief Definitions for the Shadow control server.
 */
// macros
#define BOOST_BIND_GLOBAL_PLACEHOLDERS

// standard includes
#include <algorithm>
#include <filesystem>
#include <array>
#include <cstdlib>
#include <optional>
#include <string>
#include <sstream>
#include <utility>

// lib includes
#include <boost/asio/ssl/context.hpp>
#include <boost/asio/ssl/context_base.hpp>
#include <boost/property_tree/json_parser.hpp>
#include <boost/property_tree/ptree.hpp>
#include <boost/property_tree/xml_parser.hpp>
#include <Simple-Web-Server/server_http.hpp>

// local includes
#include "config.h"
#include "display_device.h"
#include "file_handler.h"
#include "globals.h"
#include "shadow_control_http.h"
#include "shadow_http_common.h"
#include "logging.h"
#include "lumen_protocol.h"
#include "network.h"
#include "shadow_http.h"
#include "platform/common.h"
#include "process.h"
#include "rtsp.h"
#include "stream.h"
#include "system_tray.h"
#include "utility.h"
#include "uuid.h"
#include "video.h"

#ifdef _WIN32
  #include "platform/windows/virtual_display.h"
#endif

using namespace std::literals;

namespace shadow_http {

  namespace fs = std::filesystem;
  namespace pt = boost::property_tree;

  using p_named_cert_t = crypto::p_named_cert_t;
  struct client_t {
    std::vector<p_named_cert_t> named_devices;
  };

  crypto::cert_chain_t cert_chain;

  namespace {
    std::string rtsp_url_host_for_request(const std::shared_ptr<typename SimpleWeb::ServerBase<SessionHTTPS>::Request> &request) {
      auto host_header = request->header.find("host");
      if (host_header != request->header.end()) {
        auto host = host_header->second;

        if (!host.empty()) {
          auto first = host.find_first_not_of(" \t");
          if (first != std::string::npos) {
            host.erase(0, first);
          }

          auto last = host.find_last_not_of(" \t");
          if (last != std::string::npos) {
            host.erase(last + 1);
          }

          if (!host.empty()) {
            if (host.front() == '[') {
              auto end = host.find(']');
              if (end != std::string::npos) {
                return host.substr(0, end + 1);
              }
            }

            auto colon_count = std::count(host.begin(), host.end(), ':');
            if (colon_count == 1) {
              auto port_delimiter = host.rfind(':');
              if (port_delimiter != std::string::npos) {
                host.resize(port_delimiter);
              }
            } else if (colon_count > 1) {
              return "[" + host + "]";
            }

            if (!host.empty()) {
              return host;
            }
          }
        }
      }

      auto local_address = net::normalize_address(request->local_endpoint().address());
      if (local_address.is_v6() && local_address.to_v6().is_link_local()) {
        BOOST_LOG(warning) << "RTSP session URL falling back to link-local local endpoint ["sv
                           << net::addr_to_normalized_string(local_address)
                           << "] because the request Host header was unavailable"sv;
      }

      return net::addr_to_url_escaped_string(local_address);
    }

  }  // namespace

  class SessionHTTPSServer: public SimpleWeb::ServerBase<SessionHTTPS> {
  public:
    SessionHTTPSServer(const std::string &certification_file, const std::string &private_key_file):
        ServerBase<SessionHTTPS>::ServerBase(443),
        context(boost::asio::ssl::context::tls_server) {
      // Disabling TLS 1.0 and 1.1 (see RFC 8996)
      context.set_options(boost::asio::ssl::context::no_tlsv1);
      context.set_options(boost::asio::ssl::context::no_tlsv1_1);
      context.use_certificate_chain_file(certification_file);
      context.use_private_key_file(private_key_file, boost::asio::ssl::context::pem);
    }

    std::function<bool(std::shared_ptr<Request>, SSL*)> verify;
    std::function<void(std::shared_ptr<Response>, std::shared_ptr<Request>)> on_verify_failed;

  protected:
    boost::asio::ssl::context context;

    void after_bind() override {
      if (verify) {
        context.set_verify_mode(boost::asio::ssl::verify_peer | boost::asio::ssl::verify_client_once);
        context.set_verify_callback([](int verified, boost::asio::ssl::verify_context &ctx) {
          // To respond with an error message, a connection must be established
          return 1;
        });
      }
    }

    // This is Server<HTTPS>::accept() with SSL validation support added
    void accept() override {
      auto connection = create_connection(*io_service, context);

      acceptor->async_accept(connection->socket->lowest_layer(), [this, connection](const SimpleWeb::error_code &ec) {
        auto lock = connection->handler_runner->continue_lock();
        if (!lock) {
          return;
        }

        if (ec != SimpleWeb::error::operation_aborted) {
          this->accept();
        }

        auto session = std::make_shared<Session>(config.max_request_streambuf_size, connection);

        if (!ec) {
          boost::asio::ip::tcp::no_delay option(true);
          SimpleWeb::error_code ec;
          session->connection->socket->lowest_layer().set_option(option, ec);

          session->connection->set_timeout(config.timeout_request);
          session->connection->socket->async_handshake(boost::asio::ssl::stream_base::server, [this, session](const SimpleWeb::error_code &ec) {
            session->connection->cancel_timeout();
            auto lock = session->connection->handler_runner->continue_lock();
            if (!lock) {
              return;
            }
            if (!ec) {
              if (verify && !verify(session->request, session->connection->socket->native_handle())) {
                this->write(session, on_verify_failed);
              } else {
                this->read(session);
              }
            } else if (this->on_error) {
              this->on_error(session->request, ec);
            }
          });
        } else if (this->on_error) {
          this->on_error(session->request, ec);
        }
      });
    }
  };

  using https_server_t = SessionHTTPSServer;

  struct conf_intern_t {
    std::string servercert;
    std::string pkey;
  } conf_intern;

  client_t client_root;
  std::atomic<uint32_t> session_id_counter;

  using resp_https_t = std::shared_ptr<typename SimpleWeb::ServerBase<SessionHTTPS>::Response>;
  using req_https_t = std::shared_ptr<typename SimpleWeb::ServerBase<SessionHTTPS>::Request>;

  enum class op_e {
    ADD,  ///< Add certificate
    REMOVE  ///< Remove certificate
  };

    std::string get_arg(const args_t &args, const char *name, const char *default_value) {
      auto it = args.find(name);
    if (it == std::end(args)) {
      if (default_value != nullptr) {
        return std::string(default_value);
      }

      throw std::out_of_range(name);
    }
      return it->second;
    }

    std::string get_lumen_arg(const args_t &args, std::string_view name, const char *default_value = nullptr) {
      return get_arg(args, std::string(name).c_str(), default_value);
    }

    bool has_arg(const args_t &args, const char *name) {
      return args.find(name) != std::end(args);
    }

  // Helper function to extract command entries from a JSON object.
  cmd_list_t extract_command_entries(const nlohmann::json& j, const std::string& key) {
    cmd_list_t commands;

    // Check if the key exists in the JSON.
    if (j.contains(key)) {
      // Ensure that the value for the key is an array.
      try {
        for (const auto& item : j.at(key)) {
          try {
            // Extract "cmd" and "elevated" fields from the JSON object.
            std::string cmd = item.at("cmd").get<std::string>();
            bool elevated = util::get_non_string_json_value<bool>(item, "elevated", false);

            // Add the command entry to the list.
            commands.push_back({cmd, elevated});
          } catch (const std::exception& e) {
            BOOST_LOG(warning) << "Error parsing command entry: " << e.what();
          }
        }
      } catch (const std::exception &e) {
        BOOST_LOG(warning) << "Error retrieving key \"" << key << "\": " << e.what();
      }
    } else {
      BOOST_LOG(debug) << "Key \"" << key << "\" not found in the JSON.";
    }

    return commands;
  }

  void save_state() {
    nlohmann::json root = nlohmann::json::object();
    // If the state file exists, try to read it.
    if (fs::exists(config::shadow_http.file_state)) {
      try {
        std::ifstream in(config::shadow_http.file_state);
        in >> root;
      } catch (std::exception &e) {
        BOOST_LOG(error) << "Couldn't read "sv << config::shadow_http.file_state << ": "sv << e.what();
        return;
      }
    }

    // Erase any previous "root" key.
    root.erase("root");

    // Create a new "root" object and set the unique id.
    root["root"] = nlohmann::json::object();
    root["root"]["uniqueid"] = shadow_http_common::unique_id;
    if (!shadow_http_common::discovery_authority_host.empty()) {
      root["root"]["authority_host"] = shadow_http_common::discovery_authority_host;
    }

    client_t &client = client_root;
    nlohmann::json named_cert_nodes = nlohmann::json::array();

    std::unordered_set<std::string> unique_certs;
    std::unordered_map<std::string, int> name_counts;

    for (auto &named_cert_p : client.named_devices) {
      // Only add each unique certificate once.
      if (unique_certs.insert(named_cert_p->cert).second) {
        nlohmann::json named_cert_node = nlohmann::json::object();
        std::string base_name = named_cert_p->name;
        // Remove any pending id suffix (e.g., " (2)") if present.
        size_t pos = base_name.find(" (");
        if (pos != std::string::npos) {
          base_name = base_name.substr(0, pos);
        }
        int count = name_counts[base_name]++;
        std::string final_name = base_name;
        if (count > 0) {
          final_name += " (" + std::to_string(count + 1) + ")";
        }
        named_cert_node["name"] = final_name;
        named_cert_node["cert"] = named_cert_p->cert;
        named_cert_node["uuid"] = named_cert_p->uuid;
        named_cert_node["display_mode"] = named_cert_p->display_mode;
        named_cert_node["always_use_virtual_display"] = named_cert_p->always_use_virtual_display;

        // Add "do" commands if available.
        if (!named_cert_p->do_cmds.empty()) {
          nlohmann::json do_cmds_node = nlohmann::json::array();
          for (const auto &cmd : named_cert_p->do_cmds) {
            do_cmds_node.push_back(crypto::command_entry_t::serialize(cmd));
          }
          named_cert_node["do"] = do_cmds_node;
        }

        // Add "undo" commands if available.
        if (!named_cert_p->undo_cmds.empty()) {
          nlohmann::json undo_cmds_node = nlohmann::json::array();
          for (const auto &cmd : named_cert_p->undo_cmds) {
            undo_cmds_node.push_back(crypto::command_entry_t::serialize(cmd));
          }
          named_cert_node["undo"] = undo_cmds_node;
        }

        named_cert_nodes.push_back(named_cert_node);
      }
    }

    root["root"]["named_devices"] = named_cert_nodes;

    try {
      std::ofstream out(config::shadow_http.file_state);
      out << root.dump(4);  // Pretty-print with an indent of 4 spaces.
    } catch (std::exception &e) {
      BOOST_LOG(error) << "Couldn't write "sv << config::shadow_http.file_state << ": "sv << e.what();
      return;
    }
  }

  void load_state() {
    if (!fs::exists(config::shadow_http.file_state)) {
      BOOST_LOG(info) << "File "sv << config::shadow_http.file_state << " doesn't exist"sv;
      shadow_http_common::unique_id = uuid_util::uuid_t::generate().string();
      return;
    }

    nlohmann::json tree;
    try {
      std::ifstream in(config::shadow_http.file_state);
      in >> tree;
    } catch (std::exception &e) {
      BOOST_LOG(error) << "Couldn't read "sv << config::shadow_http.file_state << ": "sv << e.what();
      return;
    }

    // Check that the file contains a "root.uniqueid" value.
    if (!tree.contains("root") || !tree["root"].contains("uniqueid")) {
      shadow_http_common::uuid = uuid_util::uuid_t::generate();
      shadow_http_common::unique_id = shadow_http_common::uuid.string();
      return;
    }

    std::string uid = tree["root"]["uniqueid"];
    shadow_http_common::uuid = uuid_util::uuid_t::parse(uid);
    shadow_http_common::unique_id = uid;
    shadow_http_common::load_discovery_authority_state();

    nlohmann::json root = tree["root"];
    client_t client;  // Local client to load into

    // Import from the old format if available.
    if (root.contains("devices")) {
      for (auto &device_node : root["devices"]) {
        // For each device, if there is a "certs" array, add a named certificate.
        if (device_node.contains("certs")) {
          for (auto &el : device_node["certs"]) {
            auto named_cert_p = std::make_shared<crypto::named_cert_t>();
            named_cert_p->name = "";
            named_cert_p->cert = el.get<std::string>();
            named_cert_p->uuid = uuid_util::uuid_t::generate().string();
            named_cert_p->display_mode = "";
            named_cert_p->always_use_virtual_display = false;
            client.named_devices.emplace_back(named_cert_p);
          }
        }
      }
    }

    // Import from the new format.
    if (root.contains("named_devices")) {
      for (auto &el : root["named_devices"]) {
        auto named_cert_p = std::make_shared<crypto::named_cert_t>();
        named_cert_p->name = el.value("name", "");
        named_cert_p->cert = el.value("cert", "");
        named_cert_p->uuid = el.value("uuid", "");
        named_cert_p->display_mode = el.value("display_mode", "");
        named_cert_p->always_use_virtual_display = el.value("always_use_virtual_display", false);
        // Load command entries for "do" and "undo" keys.
        named_cert_p->do_cmds = extract_command_entries(el, "do");
        named_cert_p->undo_cmds = extract_command_entries(el, "undo");
        client.named_devices.emplace_back(named_cert_p);
      }
    }

    // Clear any existing certificate chain and add the imported certificates.
    cert_chain.clear();
    for (auto &named_cert : client.named_devices) {
      cert_chain.add(named_cert);
    }

    client_root = client;
  }

  void add_authorized_client(const p_named_cert_t& named_cert_p) {
    client_t &client = client_root;
    client.named_devices.push_back(named_cert_p);

#if defined SUNSHINE_TRAY && SUNSHINE_TRAY >= 1
    system_tray::update_tray_paired(named_cert_p->name);
#endif

    if (!config::runtime.flags[config::flag::FRESH_STATE]) {
      save_state();
      load_state();
    }
  }

  std::optional<std::string> authorize_client_certificate(
    const std::string &name,
    const std::string &uuid,
    const std::string &cert_pem,
    authorize_client_certificate_result_t *result
  ) {
    if (cert_pem.empty()) {
      return "Pairing request does not include a client certificate.";
    }

    auto cert = crypto::x509(cert_pem);
    if (!cert) {
      return "Pairing request contains an invalid PEM client certificate.";
    }

    client_t &client = client_root;
    auto existing = std::find_if(client.named_devices.begin(), client.named_devices.end(), [&](const auto &named_cert_p) {
      return named_cert_p->cert == cert_pem;
    });

    if (existing != client.named_devices.end()) {
      auto &named_cert_p = *existing;
      named_cert_p->name = name.empty() ? named_cert_p->name : name;
      named_cert_p->uuid = uuid.empty() ? named_cert_p->uuid : uuid;

      if (result) {
        result->uuid = named_cert_p->uuid;
        result->name = named_cert_p->name;
        result->already_trusted = true;
      }

      if (!config::runtime.flags[config::flag::FRESH_STATE]) {
        save_state();
        load_state();
      }

      return std::nullopt;
    }

    auto named_cert_p = std::make_shared<crypto::named_cert_t>();
    named_cert_p->name = name.empty() ? "Unnamed Device" : name;
    named_cert_p->uuid = uuid.empty() ? uuid_util::uuid_t::generate().string() : uuid;
    named_cert_p->cert = cert_pem;
    named_cert_p->display_mode = "";
    named_cert_p->always_use_virtual_display = false;
    add_authorized_client(named_cert_p);

    if (result) {
      result->uuid = named_cert_p->uuid;
      result->name = named_cert_p->name;
      result->already_trusted = false;
    }

    return std::nullopt;
  }

  std::shared_ptr<rtsp_stream::launch_session_t> make_launch_session(bool host_audio, bool input_only, const args_t &args, const crypto::named_cert_t* named_cert_p) {
    std::vector<std::string_view> missing_lumen_launch_args;
    for (const auto required_arg : lumen::protocol::launch::required_launch_args) {
      if (args.find(std::string(required_arg)) == std::end(args)) {
        missing_lumen_launch_args.emplace_back(required_arg);
      }
    }

    if (!missing_lumen_launch_args.empty()) {
      std::ostringstream missing;
      for (std::size_t index = 0; index < missing_lumen_launch_args.size(); ++index) {
        if (index != 0) {
          missing << ',';
        }
        missing << missing_lumen_launch_args[index];
      }
      BOOST_LOG(error) << "Launch request missing required Lumen sink fields: "sv << missing.str();
      return nullptr;
    }

    auto launch_session = std::make_shared<rtsp_stream::launch_session_t>();

    launch_session->id = ++session_id_counter;

    // If launched from client
    if (named_cert_p->uuid != shadow_http_common::unique_id) {
      auto rikey = util::from_hex_vec(get_arg(args, "rikey"), true);
      std::copy(rikey.cbegin(), rikey.cend(), std::back_inserter(launch_session->gcm_key));

      launch_session->host_audio = host_audio;

      // Shadow/Lumen sessions always provide the remote input keying material required
      // for encrypted RTSP setup, so do not gate encryption on legacy corever semantics.
      if (!launch_session->gcm_key.empty()) {
        launch_session->rtsp_cipher = crypto::cipher::gcm_t {
          launch_session->gcm_key, false
        };
        launch_session->rtsp_iv_counter = 0;
      }
      launch_session->rtsp_url_scheme = launch_session->rtsp_cipher ? "rtspenc://"s : "rtsp://"s;

      // Generate the unique identifiers for this connection that we will send later during RTSP handshake
      unsigned char raw_payload[8];
      RAND_bytes(raw_payload, sizeof(raw_payload));
      launch_session->av_ping_payload = util::hex_vec(raw_payload);
      RAND_bytes((unsigned char *) &launch_session->control_connect_data, sizeof(launch_session->control_connect_data));

      launch_session->iv.resize(16);
      uint32_t prepend_iv = util::endian::big<uint32_t>(static_cast<uint32_t>(util::from_view(get_arg(args, "rikeyid"))));
      auto prepend_iv_p = (uint8_t *) &prepend_iv;
      std::copy(prepend_iv_p, prepend_iv_p + sizeof(prepend_iv), std::begin(launch_session->iv));
    }

    std::stringstream mode;
    if (named_cert_p->display_mode.empty()) {
      auto mode_str = get_arg(args, "mode", config::video.fallback_mode.c_str());
      mode = std::stringstream(mode_str);
      BOOST_LOG(info) << "Display mode for client ["sv << named_cert_p->name <<"] requested to ["sv << mode_str << ']';
    } else {
      mode = std::stringstream(named_cert_p->display_mode);
      BOOST_LOG(info) << "Display mode for client ["sv << named_cert_p->name <<"] overriden to ["sv << named_cert_p->display_mode << ']';
    }

    // Split mode by the char "x", to populate width/height/fps
    int x = 0;
    std::string segment;
    while (std::getline(mode, segment, 'x')) {
      if (x == 0) {
        launch_session->width = atoi(segment.c_str());
      }
      if (x == 1) {
        launch_session->height = atoi(segment.c_str());
      }
      if (x == 2) {
        auto fps = atof(segment.c_str());
        if (fps < 1000) {
          fps *= 1000;
        };
        launch_session->fps = (int)fps;
        break;
      }
      x++;
    }

    // Parsing have failed or missing components
    if (x != 2) {
      launch_session->width = 1920;
      launch_session->height = 1080;
      launch_session->fps = 60000; // 60fps * 1000 denominator
    }

    launch_session->device_name = named_cert_p->name.empty() ? "LumenDisplay"s : named_cert_p->name;
    launch_session->unique_id = named_cert_p->uuid;
    launch_session->enable_sops = util::from_view(get_arg(args, "sops", "0"));
    launch_session->surround_info = static_cast<int>(util::from_view(get_arg(args, "surroundAudioInfo", "196610")));
    launch_session->surround_params = (get_arg(args, "surroundParams", ""));
    launch_session->gcmap = static_cast<int>(util::from_view(get_arg(args, "gcmap", "0")));
    launch_session->virtual_display = util::from_view(get_arg(args, "virtualDisplay", "0")) || named_cert_p->always_use_virtual_display;
    launch_session->sink_request = video::make_lumen_sink_request(
      {
        .scale_explicit = true,
        .mode_is_logical = util::from_view(get_lumen_arg(args, lumen::protocol::launch::sink_mode_is_logical)) != 0,
        .scale_percent = static_cast<int>(util::from_view(get_lumen_arg(args, lumen::protocol::launch::sink_scale_percent))),
        .hidpi = util::from_view(get_lumen_arg(args, lumen::protocol::launch::sink_hidpi)) != 0,
        .gamut = get_lumen_arg(args, lumen::protocol::launch::sink_gamut),
        .transfer = get_lumen_arg(args, lumen::protocol::launch::sink_transfer),
        .current_edr_headroom = get_lumen_arg(args, lumen::protocol::launch::sink_current_edr_headroom),
        .potential_edr_headroom = get_lumen_arg(args, lumen::protocol::launch::sink_potential_edr_headroom),
        .current_peak_luminance_nits = get_lumen_arg(args, lumen::protocol::launch::sink_current_peak_luminance_nits),
        .potential_peak_luminance_nits = get_lumen_arg(args, lumen::protocol::launch::sink_potential_peak_luminance_nits),
        .requested_dynamic_range_transport = get_lumen_arg(args, lumen::protocol::launch::requested_dynamic_range_transport),
        .supports_frame_gated_hdr = util::from_view(get_lumen_arg(args, lumen::protocol::launch::sink_supports_frame_gated_hdr)) != 0,
        .supports_hdr_tile_overlay = util::from_view(get_lumen_arg(args, lumen::protocol::launch::sink_supports_hdr_tile_overlay)) != 0,
        .supports_per_frame_hdr_metadata = util::from_view(get_lumen_arg(args, lumen::protocol::launch::sink_supports_per_frame_hdr_metadata)) != 0,
        .supports_encoded_tile_stream = util::from_view(get_lumen_arg(args, lumen::protocol::launch::sink_supports_encoded_tile_stream, "0")) != 0,
      }
    );
    const auto requested_dynamic_range_transport =
      video::effective_dynamic_range_transport(launch_session->sink_request.dynamic_range_transport);
    const auto negotiated_dynamic_range_transport =
      video::effective_dynamic_range_transport(launch_session->sink_request);
    const bool negotiated_hdr_stream =
      video::dynamic_range_transport_uses_hdr_stream(negotiated_dynamic_range_transport);
    BOOST_LOG(info) << "Client sink profile from launch: gamut="sv
                    << video::lumen_protocol_client_sink_gamut_name(launch_session->sink_request.capability.gamut)
                    << " transfer="sv
                    << video::lumen_protocol_client_sink_transfer_name(launch_session->sink_request.capability.transfer)
                    << " requested-transport="sv
                    << video::lumen_protocol_dynamic_range_transport_name(requested_dynamic_range_transport)
                    << " negotiated-transport="sv
                    << video::lumen_protocol_dynamic_range_transport_name(negotiated_dynamic_range_transport)
                    << " negotiated-hdr-stream="sv
                    << negotiated_hdr_stream
                    << " scale-percent="sv
                    << launch_session->sink_request.mode.scale_percent
                    << " hidpi="sv
                    << launch_session->sink_request.mode.hidpi
                    << " explicit-scale="sv
                    << launch_session->sink_request.mode.scale_explicit
                    << " mode-is-logical="sv
                    << launch_session->sink_request.mode.mode_is_logical
                    << " current-edr-headroom="sv
                    << launch_session->sink_request.capability.current_edr_headroom
                    << " potential-edr-headroom="sv
                    << launch_session->sink_request.capability.potential_edr_headroom
                    << " current-peak-nits="sv
                    << launch_session->sink_request.capability.current_peak_luminance_nits
                    << " potential-peak-nits="sv
                    << launch_session->sink_request.capability.potential_peak_luminance_nits
                    << " supports-frame-gated-hdr="sv
                    << launch_session->sink_request.capability.supports_frame_gated_hdr
                    << " supports-hdr-tile-overlay="sv
                    << launch_session->sink_request.capability.supports_hdr_tile_overlay
                    << " supports-per-frame-hdr-metadata="sv
                    << launch_session->sink_request.capability.supports_per_frame_hdr_metadata
                    << " supports-encoded-tile-stream="sv
                    << launch_session->sink_request.capability.supports_encoded_tile_stream;

    launch_session->client_do_cmds = named_cert_p->do_cmds;
    launch_session->client_undo_cmds = named_cert_p->undo_cmds;

    launch_session->input_only = input_only;

    return launch_session;
  }

  template<class T>
  struct tunnel;

  template<>
  struct tunnel<SessionHTTPS> {
    static auto constexpr to_string = "HTTPS"sv;
  };

  template<>
  struct tunnel<SimpleWeb::HTTP> {
    static auto constexpr to_string = "NONE"sv;
  };

  inline crypto::named_cert_t* get_verified_cert(req_https_t request) {
    return (crypto::named_cert_t*)request->userp.get();
  }

  inline void write_cert_verification_failed(resp_https_t response, req_https_t request) {
    pt::ptree tree;
    std::ostringstream data;

    tree.put("root.<xmlattr>.status_code"s, 401);
    tree.put("root.<xmlattr>.query"s, request->path);
    tree.put("root.<xmlattr>.status_message"s, "The client is not authorized. Certificate verification failed."s);

    pt::write_xml(data, tree);
    response->write(data.str());
    response->close_connection_after_response = true;
  }

  inline crypto::named_cert_t *require_verified_cert(resp_https_t response, req_https_t request) {
    auto *named_cert_p = get_verified_cert(request);
    if (named_cert_p) {
      return named_cert_p;
    }

    write_cert_verification_failed(response, request);
    return nullptr;
  }

  template <class T>
  void print_req(std::shared_ptr<typename SimpleWeb::ServerBase<T>::Request> request) {
    BOOST_LOG(debug) << "TUNNEL :: "sv << tunnel<T>::to_string;

    BOOST_LOG(debug) << "METHOD :: "sv << request->method;
    BOOST_LOG(debug) << "DESTINATION :: "sv << request->path;

    if (auto host_it = request->header.find("host"); host_it != request->header.end()) {
      shadow_http_common::observe_discovery_authority_host(host_it->second);
    }

    for (auto &[name, val] : request->header) {
      BOOST_LOG(debug) << name << " -- " << val;
    }

    BOOST_LOG(debug) << " [--] "sv;

    for (auto &[name, val] : request->parse_query_string()) {
      BOOST_LOG(debug) << name << " -- " << val;
    }

    BOOST_LOG(debug) << " [--] "sv;
  }

  template<class T>
  void not_found(std::shared_ptr<typename SimpleWeb::ServerBase<T>::Response> response, std::shared_ptr<typename SimpleWeb::ServerBase<T>::Request> request) {
    print_req<T>(request);

    pt::ptree tree;
    tree.put("root.<xmlattr>.status_code", 404);

    std::ostringstream data;

    pt::write_xml(data, tree);
    response->write(SimpleWeb::StatusCode::client_error_not_found, data.str());
    response->close_connection_after_response = true;
  }

  nlohmann::json get_all_clients() {
    nlohmann::json named_cert_nodes = nlohmann::json::array();
    client_t &client = client_root;
    std::list<std::string> connected_uuids = rtsp_stream::get_all_session_uuids();

    for (auto &named_cert : client.named_devices) {
      nlohmann::json named_cert_node;
      named_cert_node["name"] = named_cert->name;
      named_cert_node["uuid"] = named_cert->uuid;
      named_cert_node["display_mode"] = named_cert->display_mode;
      named_cert_node["always_use_virtual_display"] = named_cert->always_use_virtual_display;

      // Add "do" commands if available
      if (!named_cert->do_cmds.empty()) {
        nlohmann::json do_cmds_node = nlohmann::json::array();
        for (const auto &cmd : named_cert->do_cmds) {
          do_cmds_node.push_back(crypto::command_entry_t::serialize(cmd));
        }
        named_cert_node["do"] = do_cmds_node;
      }

      // Add "undo" commands if available
      if (!named_cert->undo_cmds.empty()) {
        nlohmann::json undo_cmds_node = nlohmann::json::array();
        for (const auto &cmd : named_cert->undo_cmds) {
          undo_cmds_node.push_back(crypto::command_entry_t::serialize(cmd));
        }
        named_cert_node["undo"] = undo_cmds_node;
      }

      // Determine connection status
      bool connected = false;
      if (connected_uuids.empty()) {
        connected = false;
      } else {
        for (auto it = connected_uuids.begin(); it != connected_uuids.end(); ++it) {
          if (*it == named_cert->uuid) {
            connected = true;
            connected_uuids.erase(it);
            break;
          }
        }
      }
      named_cert_node["connected"] = connected;

      named_cert_nodes.push_back(named_cert_node);
    }

    return named_cert_nodes;
  }

  void launch(bool &host_audio, resp_https_t response, req_https_t request) {
    print_req<SessionHTTPS>(request);

    pt::ptree tree;
    auto g = util::fail_guard([&]() {
      std::ostringstream data;

      pt::write_xml(data, tree);
      response->write(data.str());
      response->close_connection_after_response = true;
    });

    auto args = request->parse_query_string();

    auto appid_str = get_arg(args, "appid", "0");
    auto appuuid_str = get_arg(args, "appuuid", "");
    auto appid = util::from_view(appid_str);
    auto current_appid = proc::proc.running();
    auto current_app_uuid = proc::proc.get_running_app_uuid();
    bool is_input_only = config::input.enable_input_only_mode && (appid == proc::input_only_app_id || (appuuid_str == REMOTE_INPUT_UUID));

    const auto write_launch_status = [&](int status_code, std::string_view status_message) {
      BOOST_LOG(info) << "Launch response status="sv
                      << status_code
                      << " appid="sv
                      << appid_str
                      << " appuuid="sv
                      << appuuid_str
                      << " current-appid="sv
                      << current_appid
                      << " message="sv
                      << status_message;
      tree.put("root.<xmlattr>.status_code", status_code);
      tree.put("root.<xmlattr>.status_message", std::string(status_message));
      tree.put("root.gamesession", 0);
    };

    auto named_cert_p = require_verified_cert(response, request);
    if (!named_cert_p) {
      g.disable();
      return;
    }

    BOOST_LOG(verbose) << "Launching app [" << appid_str << "] with UUID [" << appuuid_str << "]";
    // BOOST_LOG(verbose) << "QS: " << request->query_string;
    if (
      args.find("rikey"s) == std::end(args) ||
      args.find("rikeyid"s) == std::end(args) ||
      args.find("localAudioPlayMode"s) == std::end(args) ||
      (args.find("appid"s) == std::end(args) && args.find("appuuid"s) == std::end(args))
    ) {
      tree.put("root.resume", 0);
      tree.put("root.<xmlattr>.status_code", 400);
      tree.put("root.<xmlattr>.status_message", "Missing a required launch parameter");

      return;
    }

    if (!is_input_only) {
      // Special handling for the "terminate" app
      if (
        (config::input.enable_input_only_mode && appid == proc::terminate_app_id)
        || appuuid_str == TERMINATE_APP_UUID
      ) {
        proc::proc.terminate();

        tree.put("root.resume", 0);
        tree.put("root.<xmlattr>.status_code", 410);
        tree.put("root.<xmlattr>.status_message", "App terminated.");

        return;
      }

      if (
        current_appid > 0
        && current_appid != proc::input_only_app_id
        && (
          (appid > 0 && appid != current_appid)
          || (!appuuid_str.empty() && appuuid_str != current_app_uuid)
        )
      ) {
        tree.put("root.resume", 0);
        tree.put("root.<xmlattr>.status_code", 400);
        tree.put("root.<xmlattr>.status_message", "An app is already running on this host");

        return;
      }
    }

    host_audio = util::from_view(get_arg(args, "localAudioPlayMode"));
    auto launch_session = make_launch_session(host_audio, is_input_only, args, named_cert_p);
    if (!launch_session) {
      write_launch_status(400, "Missing required Lumen v2 launch parameters");

      return;
    }

    auto encryption_mode = net::encryption_mode_for_address(request->remote_endpoint().address());
    if (!launch_session->rtsp_cipher && encryption_mode == config::ENCRYPTION_MODE_MANDATORY) {
      BOOST_LOG(error) << "Rejecting client that cannot comply with mandatory encryption requirement"sv;
      write_launch_status(403, "Encryption is mandatory for this host but unsupported by the client");

      return;
    }

    bool no_active_sessions = rtsp_stream::session_count() == 0;

    if (is_input_only) {
      BOOST_LOG(info) << "Launching input only session..."sv;

      launch_session->client_do_cmds.clear();
      launch_session->client_undo_cmds.clear();

      // Still probe encoders once, if input only session is launched first
      // But we're ignoring if it's successful or not
      if (no_active_sessions && !proc::proc.virtual_display) {
        video::probe_encoders();
        if (current_appid == 0) {
          proc::proc.launch_input_only();
        }
      }
    } else if (appid > 0 || !appuuid_str.empty()) {
      if (appid == current_appid || (!appuuid_str.empty() && appuuid_str == current_app_uuid)) {
        // We're basically resuming the same app

        BOOST_LOG(debug) << "Resuming app [" << proc::proc.get_last_run_app_name() << "] from launch app path...";

        if (current_appid == proc::input_only_app_id) {
          launch_session->input_only = true;
        }

        if (no_active_sessions && !proc::proc.virtual_display) {
          display_device::configure_display(config::video, *launch_session);
          if (video::probe_encoders()) {
            tree.put("root.resume", 0);
            write_launch_status(503, "Failed to initialize video capture/encoding. Is a display connected and turned on?");

            return;
          }
        }
      } else {
        const auto& apps = proc::proc.get_apps();
        auto app_iter = std::find_if(apps.begin(), apps.end(), [&appid_str, &appuuid_str](const auto _app) {
          return _app.id == appid_str || _app.uuid == appuuid_str;
        });

        if (app_iter == apps.end()) {
          BOOST_LOG(error) << "Couldn't find app with ID ["sv << appid_str << "] or UUID ["sv << appuuid_str << ']';
          tree.put("root.<xmlattr>.status_code", 404);
          tree.put("root.<xmlattr>.status_message", "Cannot find requested application");
          tree.put("root.gamesession", 0);
          return;
        }

        auto err = proc::proc.execute(*app_iter, launch_session);
        if (err) {
          write_launch_status(
            err,
            err == 503
              ? "Failed to initialize video capture/encoding. Is a display connected and turned on?"
              : "Failed to start the specified application"
          );

          return;
        }
      }
    } else {
      write_launch_status(403, "How did you get here?");
    }

    BOOST_LOG(info) << "Launch response status=200 appid="sv << appid_str << " appuuid="sv << appuuid_str << " current-appid="sv << current_appid;
    tree.put("root.<xmlattr>.status_code", 200);
    auto session_url_host = rtsp_url_host_for_request(request);
    std::ostringstream session_url_stream;
    session_url_stream
      << launch_session->rtsp_url_scheme
      << session_url_host
      << ':'
      << static_cast<int>(net::map_port(rtsp_stream::RTSP_SETUP_PORT));
    auto session_url = session_url_stream.str();
    BOOST_LOG(info) << "Launch session URL resolved to ["sv << session_url << "] from local endpoint ["sv
                    << net::addr_to_normalized_string(request->local_endpoint().address()) << ']';
    tree.put("root.sessionUrl0", session_url);
    tree.put("root.gamesession", 1);

    rtsp_stream::launch_session_raise(launch_session);
  }

  void resume(bool &host_audio, resp_https_t response, req_https_t request) {
    print_req<SessionHTTPS>(request);

    pt::ptree tree;
    auto g = util::fail_guard([&]() {
      std::ostringstream data;

      pt::write_xml(data, tree);
      response->write(data.str());
      response->close_connection_after_response = true;
    });

    auto named_cert_p = require_verified_cert(response, request);
    if (!named_cert_p) {
      g.disable();
      return;
    }

    auto current_appid = proc::proc.running();
    if (current_appid == 0) {
      tree.put("root.resume", 0);
      tree.put("root.<xmlattr>.status_code", 503);
      tree.put("root.<xmlattr>.status_message", "No running app to resume");

      return;
    }

    auto args = request->parse_query_string();
    if (
      args.find("rikey"s) == std::end(args) ||
      args.find("rikeyid"s) == std::end(args)
    ) {
      tree.put("root.resume", 0);
      tree.put("root.<xmlattr>.status_code", 400);
      tree.put("root.<xmlattr>.status_message", "Missing a required resume parameter");

      return;
    }

    // Newer Moonlight clients send localAudioPlayMode on /resume too,
    // so we should use it if it's present in the args and there are
    // no active sessions we could be interfering with.
    const bool no_active_sessions {rtsp_stream::session_count() == 0};
    if (no_active_sessions && args.find("localAudioPlayMode"s) != std::end(args)) {
      host_audio = util::from_view(get_arg(args, "localAudioPlayMode"));
    }
    auto launch_session = make_launch_session(host_audio, false, args, named_cert_p);
    if (!launch_session) {
      tree.put("root.resume", 0);
      tree.put("root.<xmlattr>.status_code", 400);
      tree.put("root.<xmlattr>.status_message", "Missing required Lumen v2 resume parameters");

      return;
    }

    if (config::input.enable_input_only_mode && current_appid == proc::input_only_app_id) {
      launch_session->input_only = true;
    }

    if (no_active_sessions && !proc::proc.virtual_display) {
      // We want to prepare display only if there are no active sessions
      // and the current session isn't virtual display at the moment.
      // This should be done before probing encoders as it could change the active displays.
      display_device::configure_display(config::video, *launch_session);

      // Probe encoders again before streaming to ensure our chosen
      // encoder matches the active GPU (which could have changed
      // due to hotplugging, driver crash, primary monitor change,
      // or any number of other factors).
      if (video::probe_encoders()) {
        tree.put("root.resume", 0);
        tree.put("root.<xmlattr>.status_code", 503);
        tree.put("root.<xmlattr>.status_message", "Failed to initialize video capture/encoding. Is a display connected and turned on?");

        return;
      }
    }

    auto encryption_mode = net::encryption_mode_for_address(request->remote_endpoint().address());
    if (!launch_session->rtsp_cipher && encryption_mode == config::ENCRYPTION_MODE_MANDATORY) {
      BOOST_LOG(error) << "Rejecting client that cannot comply with mandatory encryption requirement"sv;

      tree.put("root.<xmlattr>.status_code", 403);
      tree.put("root.<xmlattr>.status_message", "Encryption is mandatory for this host but unsupported by the client");
      tree.put("root.gamesession", 0);

      return;
    }

    tree.put("root.<xmlattr>.status_code", 200);
    auto session_url_host = rtsp_url_host_for_request(request);
    std::ostringstream session_url_stream;
    session_url_stream
      << launch_session->rtsp_url_scheme
      << session_url_host
      << ':'
      << static_cast<int>(net::map_port(rtsp_stream::RTSP_SETUP_PORT));
    auto session_url = session_url_stream.str();
    BOOST_LOG(info) << "Resume session URL resolved to ["sv << session_url << "] from local endpoint ["sv
                    << net::addr_to_normalized_string(request->local_endpoint().address()) << ']';
    tree.put("root.sessionUrl0", session_url);
    tree.put("root.resume", 1);

    rtsp_stream::launch_session_raise(launch_session);

#if defined SUNSHINE_TRAY && SUNSHINE_TRAY >= 1
    system_tray::update_tray_client_connected(named_cert_p->name);
#endif
  }

  void cancel(resp_https_t response, req_https_t request) {
    print_req<SessionHTTPS>(request);

    pt::ptree tree;
    auto g = util::fail_guard([&]() {
      std::ostringstream data;

      pt::write_xml(data, tree);
      response->write(data.str());
      response->close_connection_after_response = true;
    });

    auto named_cert_p = require_verified_cert(response, request);
    if (!named_cert_p) {
      g.disable();
      return;
    }

    tree.put("root.cancel", 1);
    tree.put("root.<xmlattr>.status_code", 200);

    rtsp_stream::terminate_sessions();

    if (proc::proc.running() > 0) {
      proc::proc.terminate();
    }

    // The config needs to be reverted regardless of whether "proc::proc.terminate()" was called or not.
    display_device::revert_configuration();
  }

  void appasset(resp_https_t response, req_https_t request) {
    print_req<SessionHTTPS>(request);

    auto fg = util::fail_guard([&]() {
      response->write(SimpleWeb::StatusCode::server_error_internal_server_error);
      response->close_connection_after_response = true;
    });

    auto named_cert_p = require_verified_cert(response, request);
    if (!named_cert_p) {
      fg.disable();
      return;
    }

    auto args = request->parse_query_string();
    auto app_image = proc::proc.get_app_image(static_cast<int>(util::from_view(get_arg(args, "appid"))));

    fg.disable();

    std::ifstream in(app_image, std::ios::binary);
    SimpleWeb::CaseInsensitiveMultimap headers;
    headers.emplace("Content-Type", "image/png");
    response->write(SimpleWeb::StatusCode::success_ok, in, headers);
    response->close_connection_after_response = true;
  }

  void getClipboard(resp_https_t response, req_https_t request) {
    print_req<SessionHTTPS>(request);

    auto named_cert_p = require_verified_cert(response, request);
    if (!named_cert_p) {
      return;
    }

    auto args = request->parse_query_string();
    auto clipboard_type = get_arg(args, "type");
    if (clipboard_type != "text"sv) {
      BOOST_LOG(debug) << "Clipboard type [" << clipboard_type << "] is not supported!";

      response->write(SimpleWeb::StatusCode::client_error_bad_request);
      response->close_connection_after_response = true;
      return;
    }

    std::list<std::string> connected_uuids = rtsp_stream::get_all_session_uuids();

    bool found = !connected_uuids.empty();

    if (found) {
      found = (std::find(connected_uuids.begin(), connected_uuids.end(), named_cert_p->uuid) != connected_uuids.end());
    }

    if (!found) {
      BOOST_LOG(debug) << "Client ["<< named_cert_p->name << "] trying to get clipboard is not connected to a stream";

      response->write(SimpleWeb::StatusCode::client_error_forbidden);
      response->close_connection_after_response = true;
      return;
    }

    std::string content = platf::get_clipboard();
    response->write(content);
    return;
  }

  void
  setClipboard(resp_https_t response, req_https_t request) {
    print_req<SessionHTTPS>(request);

    auto named_cert_p = require_verified_cert(response, request);
    if (!named_cert_p) {
      return;
    }

    auto args = request->parse_query_string();
    auto clipboard_type = get_arg(args, "type");
    if (clipboard_type != "text"sv) {
      BOOST_LOG(debug) << "Clipboard type [" << clipboard_type << "] is not supported!";

      response->write(SimpleWeb::StatusCode::client_error_bad_request);
      response->close_connection_after_response = true;
      return;
    }

    std::list<std::string> connected_uuids = rtsp_stream::get_all_session_uuids();

    bool found = !connected_uuids.empty();

    if (found) {
      found = (std::find(connected_uuids.begin(), connected_uuids.end(), named_cert_p->uuid) != connected_uuids.end());
    }

    if (!found) {
      BOOST_LOG(debug) << "Client ["<< named_cert_p->name << "] trying to set clipboard is not connected to a stream";

      response->write(SimpleWeb::StatusCode::client_error_forbidden);
      response->close_connection_after_response = true;
      return;
    }

    std::string content = request->content.string();

    bool success = platf::set_clipboard(content);

    if (!success) {
      BOOST_LOG(debug) << "Setting clipboard failed!";

      response->write(SimpleWeb::StatusCode::server_error_internal_server_error);
      response->close_connection_after_response = true;
    }

    response->write();
    return;
  }

  void setup(const std::string &pkey, const std::string &cert) {
    conf_intern.pkey = pkey;
    conf_intern.servercert = cert;
  }

  void start() {
    auto shutdown_event = mail::man->event<bool>(mail::shutdown);

    auto port_https = net::map_port(PORT_HTTPS);
    auto address_family = net::af_from_enum_string(config::runtime.address_family);

    bool clean_slate = config::runtime.flags[config::flag::FRESH_STATE];

    if (!clean_slate) {
      load_state();
    }

    auto pkey = file_handler::read_file(config::shadow_http.pkey.c_str());
    auto cert = file_handler::read_file(config::shadow_http.cert.c_str());
    setup(pkey, cert);

    // resume doesn't always get the parameter "localAudioPlayMode"
    // launch will store it in host_audio
    bool host_audio {};

    https_server_t https_server {config::shadow_http.cert, config::shadow_http.pkey};

    // Verify certificates after establishing connection
    https_server.verify = [](req_https_t req, SSL *ssl) {
      crypto::x509_t x509 {
#if OPENSSL_VERSION_MAJOR >= 3
        SSL_get1_peer_certificate(ssl)
#else
        SSL_get_peer_certificate(ssl)
#endif
      };
      if (!x509) {
        req->userp.reset();
        BOOST_LOG(debug) << "No client certificate presented during HTTPS handshake"sv;
        return true;
      }

      bool verified = false;
      p_named_cert_t named_cert_p;

      auto fg = util::fail_guard([&]() {
        char subject_name[256];

        X509_NAME_oneline(X509_get_subject_name(x509.get()), subject_name, sizeof(subject_name));

        if (verified) {
          BOOST_LOG(debug) << subject_name << " -- "sv << "verified, device name: "sv << named_cert_p->name;
        } else {
          BOOST_LOG(debug) << subject_name << " -- "sv << "denied"sv;
        }

      });

      auto err_str = cert_chain.verify(x509.get(), named_cert_p);
      if (err_str) {
        req->userp.reset();
        BOOST_LOG(warning) << "SSL Verification error :: "sv << err_str;
        return true;
      }

      verified = true;
      req->userp = named_cert_p;

      return true;
    };

    https_server.on_verify_failed = [](resp_https_t resp, req_https_t req) {
      pt::ptree tree;
      auto g = util::fail_guard([&]() {
        std::ostringstream data;

        pt::write_xml(data, tree);
        resp->write(data.str());
        resp->close_connection_after_response = true;
      });

      tree.put("root.<xmlattr>.status_code"s, 401);
      tree.put("root.<xmlattr>.query"s, req->path);
      tree.put("root.<xmlattr>.status_message"s, "The client is not authorized. Certificate verification failed."s);
    };

    https_server.default_resource["GET"] = not_found<SessionHTTPS>;
    https_server.resource["^/appasset$"]["GET"] = appasset;
    https_server.resource["^/launch$"]["GET"] = [&host_audio](auto resp, auto req) {
      launch(host_audio, resp, req);
    };
    https_server.resource["^/resume$"]["GET"] = [&host_audio](auto resp, auto req) {
      resume(host_audio, resp, req);
    };
    https_server.resource["^/cancel$"]["GET"] = cancel;
    https_server.resource["^/actions/clipboard$"]["GET"] = getClipboard;
    https_server.resource["^/actions/clipboard$"]["POST"] = setClipboard;

    https_server.config.reuse_address = true;
    https_server.config.address = net::af_to_any_address_string(address_family);
    https_server.config.port = port_https;

    auto accept_and_run = [&](auto *http_server) {
      try {
        http_server->start();
      } catch (boost::system::system_error &err) {
        // It's possible the exception gets thrown after calling http_server->stop() from a different thread
        if (shutdown_event->peek()) {
          return;
        }

        BOOST_LOG(fatal) << "Couldn't start Shadow control server on port ["sv << port_https << "]: "sv << err.what();
        shutdown_event->raise(true);
        return;
      }
    };
    std::thread https_thread {accept_and_run, &https_server};

    // Wait for any event
    shutdown_event->view();

    https_server.stop();

    https_thread.join();
  }

  void
  erase_all_clients() {
    client_t client;
    client_root = client;
    cert_chain.clear();
    save_state();
    load_state();
  }

  void stop_session(stream::session_t& session, bool graceful) {
    if (graceful) {
      stream::session::graceful_stop(session);
    } else {
      stream::session::stop(session);
    }
  }

  bool find_and_stop_session(const std::string& uuid, bool graceful) {
    auto session = rtsp_stream::find_session(uuid);
    if (session) {
      stop_session(*session, graceful);
      return true;
    }
    return false;
  }

  void update_session_info(stream::session_t& session, const std::string& name) {
    stream::session::update_device_info(session, name);
  }

  bool find_and_udpate_session_info(const std::string& uuid, const std::string& name) {
    auto session = rtsp_stream::find_session(uuid);
    if (session) {
      update_session_info(*session, name);
      return true;
    }
    return false;
  }

  bool update_device_info(
    const std::string& uuid,
    const std::string& name,
    const std::string& display_mode,
    const cmd_list_t& do_cmds,
    const cmd_list_t& undo_cmds,
    const bool always_use_virtual_display
  ) {
    find_and_udpate_session_info(uuid, name);

    client_t &client = client_root;
    auto it = client.named_devices.begin();
    for (; it != client.named_devices.end(); ++it) {
      auto named_cert_p = *it;
      if (named_cert_p->uuid == uuid) {
        named_cert_p->name = name;
        named_cert_p->display_mode = display_mode;
        named_cert_p->do_cmds = do_cmds;
        named_cert_p->undo_cmds = undo_cmds;
        named_cert_p->always_use_virtual_display = always_use_virtual_display;
        save_state();
        return true;
      }
    }

    return false;
  }

  bool unpair_client(const std::string_view uuid) {
    bool removed = false;
    client_t &client = client_root;
    for (auto it = client.named_devices.begin(); it != client.named_devices.end();) {
      if ((*it)->uuid == uuid) {
        it = client.named_devices.erase(it);
        removed = true;
      } else {
        ++it;
      }
    }

    save_state();
    load_state();

    if (removed) {
      auto session = rtsp_stream::find_session(uuid);
      if (session) {
        stop_session(*session, true);
      }

      if (client.named_devices.empty()) {
        proc::proc.terminate();
      }
    }

    return removed;
  }
}  // namespace shadow_http
