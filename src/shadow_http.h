/**
 * @file src/shadow_http.h
 * @brief Declarations for the Shadow control server.
 */
// macros
#pragma once

// standard includes
#include <string>
#include <chrono>
#include <list>
#include <optional>

// lib includes
#include <boost/property_tree/ptree.hpp>
#include <nlohmann/json.hpp>
#include <Simple-Web-Server/server_https.hpp>

// local includes
#include "crypto.h"
#include "rtsp.h"
#include "thread_safe.h"

using namespace std::chrono_literals;

/**
 * @brief Contains the functions and state used by the Shadow control server.
 */
namespace shadow_http {

  using args_t = SimpleWeb::CaseInsensitiveMultimap;
  using cmd_list_t = std::list<crypto::command_entry_t>;

  struct authorize_client_certificate_result_t {
    std::string uuid;
    std::string name;
    bool already_trusted = false;
  };

  /**
   * @brief The HTTPS port, as a difference from the config port.
   */
  constexpr auto PORT_HTTPS = -5;

  constexpr auto OTP_EXPIRE_DURATION = 180s;

  /**
   * @brief Start the Shadow control server.
   * @examples
   * shadow_http::start();
   * @examples_end
   */
  void start();

  std::string
  get_arg(const args_t &args, const char *name, const char *default_value = nullptr);

  // Helper function to extract command entries
  cmd_list_t
  extract_command_entries(const nlohmann::json& j, const std::string& key);

  std::shared_ptr<rtsp_stream::launch_session_t>
  make_launch_session(bool host_audio, bool input_only, const args_t &args, const crypto::named_cert_t* named_cert_p);

  /**
   * @brief Setup the session HTTP server.
   * @param pkey
   * @param cert
   */
  void setup(const std::string &pkey, const std::string &cert);

  class SessionHTTPS: public SimpleWeb::HTTPS {
  public:
    SessionHTTPS(boost::asio::io_context &io_context, boost::asio::ssl::context &ctx):
        SimpleWeb::HTTPS(io_context, ctx) {
    }

    virtual ~SessionHTTPS() {
      // Gracefully shutdown the TLS connection
      SimpleWeb::error_code ec;
      shutdown(ec);
    }
  };

  /**
   * @brief Remove single client.
   * @param uuid The UUID of the client to remove.
   * @examples
   * shadow_http::unpair_client("4D7BB2DD-5704-A405-B41C-891A022932E1");
   * @examples_end
   */
  bool unpair_client(std::string_view uuid);

  /**
   * @brief Get all paired clients.
   * @return The list of all paired clients.
   * @examples
   * nlohmann::json clients = shadow_http::get_all_clients();
   * @examples_end
   */
  nlohmann::json get_all_clients();

  /**
   * @brief Remove all paired clients.
   * @examples
   * shadow_http::erase_all_clients();
   * @examples_end
   */
  void erase_all_clients();

  /**
   * @brief Trust a client certificate for Shadow control and streaming sessions.
   * @param name The display name to store for the device.
   * @param uuid The stable client identifier, if provided by the client.
   * @param cert_pem The PEM encoded client certificate to trust.
   * @return An error message when the certificate cannot be trusted.
   */
  std::optional<std::string> authorize_client_certificate(
    const std::string &name,
    const std::string &uuid,
    const std::string &cert_pem,
    authorize_client_certificate_result_t *result = nullptr
  );

  /**
   * @brief      Stops a session.
   *
   * @param      session   The session
   * @param[in]  graceful  Whether to stop gracefully
   */
  void stop_session(stream::session_t& session, bool graceful);

  /**
   * @brief      Finds and stop session.
   *
   * @param[in]  uuid      The uuid string
   * @param[in]  graceful  Whether to stop gracefully
   */
  bool find_and_stop_session(const std::string& uuid, bool graceful);

  /**
   * @brief      Update device info associated to the session
   *
   * @param      session  The session
   * @param[in]  name     New name
   * @param[in]  newPerm  New permission
   */
  void update_session_info(stream::session_t& session, const std::string& name, const crypto::PERM newPerm);

  /**
   * @brief      Finds and udpate session information.
   *
   * @param[in]  uuid     The uuid string
   * @param[in]  name     New name
   * @param[in]  newPerm  New permission
   */
  bool find_and_udpate_session_info(const std::string& uuid, const std::string& name, const crypto::PERM newPerm);

  /**
   * @brief      Update device info
   *
   * @param[in]  uuid       The uuid string
   * @param[in]  name       New name
   * @param[in]  do_cmds    The do commands
   * @param[in]  undo_cmds  The undo commands
   * @param[in]  newPerm    New permission
   * @param[in]  enable_legacy_ordering  Enable legacy ordering
   * @param[in]  allow_client_commands  Allow client commands
   * @param[in]  always_use_virtual_display  Always use virtual display
   * 
   * @return     Whether the update is successful
   */
  bool update_device_info(
    const std::string& uuid,
    const std::string& name,
    const std::string& display_mode,
    const cmd_list_t& do_cmds,
    const cmd_list_t& undo_cmds,
    const crypto::PERM newPerm,
    const bool enable_legacy_ordering,
    const bool allow_client_commands,
    const bool always_use_virtual_display
  );
}  // namespace shadow_http
