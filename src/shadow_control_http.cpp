/**
 * @file src/shadow_control_http.cpp
 * @brief Definitions for the Shadow control Web UI HTTPS server.
 *
 * @todo Authentication, better handling of routes shared with the Shadow control server, cleanup
 */
#define BOOST_BIND_GLOBAL_PLACEHOLDERS

// standard includes
#include <filesystem>
#include <fstream>
#include <mutex>
#include <optional>
#include <set>
#include <sstream>
#include <thread>
#include <unordered_map>
#include <numeric>
#include <algorithm>

// lib includes
#include <boost/algorithm/string.hpp>
#include <boost/asio/ssl/context.hpp>
#include <boost/filesystem.hpp>
#include <nlohmann/json.hpp>
#include <Simple-Web-Server/crypto.hpp>
#include <Simple-Web-Server/server_https.hpp>

// local includes
#include "config.h"
#include "shadow_control_http.h"
#include "crypto.h"
#include "display_device.h"
#include "file_handler.h"
#include "globals.h"
#include "shadow_http_common.h"
#include "logging.h"
#include "network.h"
#include "shadow_http.h"
#include "platform/common.h"
#include "process.h"
#include "system_tray.h"
#include "utility.h"
#include "uuid.h"

#ifdef __APPLE__
  #include "platform/macos/misc.h"
#endif

#ifdef _WIN32
  #include "platform/windows/utils.h"
#endif

using namespace std::literals;

namespace shadow_control_http {
  namespace fs = std::filesystem;

  using https_server_t = SimpleWeb::Server<SimpleWeb::HTTPS>;
  using args_t = SimpleWeb::CaseInsensitiveMultimap;
  using resp_https_t = std::shared_ptr<typename SimpleWeb::ServerBase<SimpleWeb::HTTPS>::Response>;
  using req_https_t = std::shared_ptr<typename SimpleWeb::ServerBase<SimpleWeb::HTTPS>::Request>;

  // Keep the base enum for client operations.
  enum class op_e {
    ADD,    ///< Add client
    REMOVE  ///< Remove client
  };

  // SESSION COOKIE
  std::string sessionCookie;
  static std::chrono::time_point<std::chrono::steady_clock> cookie_creation_time;

  constexpr auto SHADOW_PAIRING_EXPIRE_DURATION = 10min;
  constexpr auto SHADOW_PAIRING_POLL_INTERVAL = 2s;

  enum class shadow_pairing_status_e {
    pending,
    approved,
    rejected,
  };

  struct shadow_pairing_request_t {
    std::string pairing_id;
    std::string user_code;
    std::string device_name;
    std::string platform;
    std::string client_id;
    std::string public_key;
    std::string trusted_client_uuid;
    bool client_trusted = false;
    std::chrono::time_point<std::chrono::steady_clock> created_at;
    std::chrono::time_point<std::chrono::steady_clock> expires_at;
    shadow_pairing_status_e status = shadow_pairing_status_e::pending;
  };

  std::mutex shadow_pairing_requests_mutex;
  std::unordered_map<std::string, shadow_pairing_request_t> shadow_pairing_requests;

  std::string shadow_pairing_status_string(const shadow_pairing_request_t &request) {
    if (std::chrono::steady_clock::now() > request.expires_at) {
      return "expired";
    }

    switch (request.status) {
      case shadow_pairing_status_e::pending:
        return "pending";
      case shadow_pairing_status_e::approved:
        return "approved";
      case shadow_pairing_status_e::rejected:
        return "rejected";
    }

    return "expired";
  }

  void erase_expired_shadow_pairing_requests_locked() {
    const auto now = std::chrono::steady_clock::now();
    for (auto it = shadow_pairing_requests.begin(); it != shadow_pairing_requests.end();) {
      if (now > it->second.expires_at) {
        it = shadow_pairing_requests.erase(it);
      } else {
        ++it;
      }
    }
  }

  void append_shadow_pairing_host_details(nlohmann::json &tree) {
    tree["clientCertificateRequired"] = true;
    tree["serverUniqueId"] = shadow_http_common::unique_id;
    tree["serviceType"] = SERVICE_TYPE;
    tree["controlHttpsPort"] = net::map_port(PORT_HTTPS);
  }

  std::string normalized_request_host(req_https_t request) {
    auto host_it = request->header.find("host");
    if (host_it == request->header.end()) {
      return {};
    }

    auto host = host_it->second;
    boost::trim(host);
    if (host.empty()) {
      return {};
    }

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

    return host;
  }

  void append_shadow_pairing_control_url_candidate(
    nlohmann::json::array_t &urls,
    std::set<std::string> &seen,
    const std::string &host
  ) {
    auto trimmed_host = host;
    boost::trim(trimmed_host);
    if (trimmed_host.empty()) {
      return;
    }

    const auto url = "https://"s + trimmed_host + ":"s + std::to_string(net::map_port(PORT_HTTPS));
    if (seen.emplace(url).second) {
      urls.push_back(url);
    }
  }

  void append_shadow_pairing_host_details(nlohmann::json &tree, req_https_t request) {
    append_shadow_pairing_host_details(tree);

    nlohmann::json::array_t control_urls;
    std::set<std::string> seen_urls;

    const auto local_address = net::normalize_address(request->local_endpoint().address());
    if (!local_address.is_loopback() && !(local_address.is_v6() && local_address.to_v6().is_link_local())) {
      append_shadow_pairing_control_url_candidate(
        control_urls,
        seen_urls,
        net::addr_to_url_escaped_string(local_address)
      );
    }

    for (const auto &interface_address : net::local_interface_addresses()) {
      if (interface_address.is_loopback()) {
        continue;
      }
      if (interface_address.is_v6() && interface_address.to_v6().is_link_local()) {
        continue;
      }

      append_shadow_pairing_control_url_candidate(
        control_urls,
        seen_urls,
        net::addr_to_url_escaped_string(interface_address)
      );
    }

    append_shadow_pairing_control_url_candidate(control_urls, seen_urls, normalized_request_host(request));

    append_shadow_pairing_control_url_candidate(control_urls, seen_urls, config::shadow_http.external_ip);
    append_shadow_pairing_control_url_candidate(control_urls, seen_urls, config::shadow_http.host_name);

    tree["controlHttpsUrls"] = control_urls;
    tree["preferredControlHttpsUrl"] = control_urls.empty() ? ""s : control_urls.front().get<std::string>();
  }

  nlohmann::json serialize_shadow_pairing_request(const shadow_pairing_request_t &request) {
    const auto now = std::chrono::steady_clock::now();
    const auto expires_in = std::max<int64_t>(
      0,
      std::chrono::duration_cast<std::chrono::seconds>(request.expires_at - now).count()
    );

    nlohmann::json tree;
    tree["pairingId"] = request.pairing_id;
    tree["userCode"] = request.user_code;
    tree["deviceName"] = request.device_name;
    tree["platform"] = request.platform;
    tree["clientId"] = request.client_id;
    tree["trustedClientUuid"] = request.trusted_client_uuid;
    tree["publicKeyPresent"] = !request.public_key.empty();
    tree["clientTrusted"] = request.client_trusted;
    tree["status"] = shadow_pairing_status_string(request);
    tree["expiresInSeconds"] = expires_in;
    tree["pollIntervalSeconds"] = SHADOW_PAIRING_POLL_INTERVAL.count();
    append_shadow_pairing_host_details(tree);
    return tree;
  }

  shadow_pairing_request_snapshot_t snapshot_shadow_pairing_request(const shadow_pairing_request_t &request) {
    const auto now = std::chrono::steady_clock::now();

    shadow_pairing_request_snapshot_t snapshot;
    snapshot.pairing_id = request.pairing_id;
    snapshot.user_code = request.user_code;
    snapshot.device_name = request.device_name;
    snapshot.platform = request.platform;
    snapshot.client_id = request.client_id;
    snapshot.trusted_client_uuid = request.trusted_client_uuid;
    snapshot.public_key_present = !request.public_key.empty();
    snapshot.client_trusted = request.client_trusted;
    snapshot.client_certificate_required = true;
    snapshot.status = shadow_pairing_status_string(request);
    snapshot.server_unique_id = shadow_http_common::unique_id;
    snapshot.service_type = SERVICE_TYPE;
    snapshot.control_https_port = net::map_port(PORT_HTTPS);
    snapshot.expires_in_seconds = std::max<int64_t>(
      0,
      std::chrono::duration_cast<std::chrono::seconds>(request.expires_at - now).count()
    );
    snapshot.poll_interval_seconds = SHADOW_PAIRING_POLL_INTERVAL.count();
    return snapshot;
  }

  std::string generate_shadow_pairing_user_code() {
    static constexpr auto alphabet = "ABCDEFGHJKLMNPQRSTUVWXYZ23456789"sv;
    return crypto::rand_alphabet(6, alphabet);
  }

  std::optional<std::string> resolve_shadow_pairing_request_id(
    const nlohmann::json &input_tree,
    const std::unordered_map<std::string, shadow_pairing_request_t> &requests
  ) {
    if (input_tree.contains("pairingId") && input_tree["pairingId"].is_string()) {
      auto pairing_id = input_tree["pairingId"].get<std::string>();
      if (requests.find(pairing_id) != requests.end()) {
        return pairing_id;
      }
    }

    if (input_tree.contains("userCode") && input_tree["userCode"].is_string()) {
      auto user_code = input_tree["userCode"].get<std::string>();
      auto it = std::find_if(requests.begin(), requests.end(), [&user_code](const auto &entry) {
        return entry.second.user_code == user_code;
      });
      if (it != requests.end()) {
        return it->first;
      }
    }

    return std::nullopt;
  }

  shadow_pairing_request_snapshot_t create_pairing_request(
    std::string device_name,
    std::string platform,
    std::string client_id,
    std::string public_key
  ) {
    shadow_pairing_request_t pairing_request;
    pairing_request.pairing_id = uuid_util::uuid_t::generate().string();
    pairing_request.user_code = generate_shadow_pairing_user_code();
    pairing_request.device_name = device_name.empty() ? "Unnamed Device"s : std::move(device_name);
    pairing_request.platform = platform.empty() ? "unknown"s : std::move(platform);
    pairing_request.client_id = std::move(client_id);
    pairing_request.public_key = std::move(public_key);
    pairing_request.created_at = std::chrono::steady_clock::now();
    pairing_request.expires_at = pairing_request.created_at + SHADOW_PAIRING_EXPIRE_DURATION;

    {
      std::lock_guard lock {shadow_pairing_requests_mutex};
      erase_expired_shadow_pairing_requests_locked();
      shadow_pairing_requests[pairing_request.pairing_id] = pairing_request;
    }

    BOOST_LOG(info) << "Shadow pairing request created for ["sv << pairing_request.device_name
                    << "] platform ["sv << pairing_request.platform << "] code ["sv
                    << pairing_request.user_code << ']';

    system_tray::update_tray_require_pairing_approval(pairing_request.device_name, pairing_request.user_code);

    return snapshot_shadow_pairing_request(pairing_request);
  }

  /**
   * @brief Log the request details.
   * @param request The HTTP request object.
   */
  void print_req(const req_https_t &request) {
    BOOST_LOG(debug) << "METHOD :: "sv << request->method;
    BOOST_LOG(debug) << "DESTINATION :: "sv << request->path;
    for (auto &[name, val] : request->header) {
      BOOST_LOG(debug) << name << " -- " << (name == "Authorization" ? "CREDENTIALS REDACTED" : val);
    }
    BOOST_LOG(debug) << " [--] "sv;
    for (auto &[name, val] : request->parse_query_string()) {
      BOOST_LOG(debug) << name << " -- " << val;
    }
    BOOST_LOG(debug) << " [--] "sv;
  }

  /**
   * @brief Send a response.
   * @param response The HTTP response object.
   * @param output_tree The JSON tree to send.
   */
  void send_response(resp_https_t response, const nlohmann::json &output_tree) {
    SimpleWeb::CaseInsensitiveMultimap headers;
    headers.emplace("Content-Type", "application/json");
    headers.emplace("X-Frame-Options", "DENY");
    headers.emplace("Content-Security-Policy", "frame-ancestors 'none';");
    response->write(output_tree.dump(), headers);
  }

  /**
   * @brief Send a 401 Unauthorized response.
   * @param response The HTTP response object.
   * @param request The HTTP request object.
   */
  void send_unauthorized(resp_https_t response, req_https_t request) {
    auto address = net::addr_to_normalized_string(request->remote_endpoint().address());
    BOOST_LOG(info) << "Web UI: ["sv << address << "] -- not authorized"sv;
    constexpr SimpleWeb::StatusCode code = SimpleWeb::StatusCode::client_error_unauthorized;
    nlohmann::json tree;
    tree["status_code"] = code;
    tree["status"] = false;
    tree["error"] = "Unauthorized";
    const SimpleWeb::CaseInsensitiveMultimap headers {
      {"Content-Type", "application/json"},
      {"X-Frame-Options", "DENY"},
      {"Content-Security-Policy", "frame-ancestors 'none';"}
    };
    response->write(code, tree.dump(), headers);
  }

  /**
   * @brief Send a redirect response.
   * @param response The HTTP response object.
   * @param request The HTTP request object.
   * @param path The path to redirect to.
   */
  void send_redirect(resp_https_t response, req_https_t request, const char *path) {
    auto address = net::addr_to_normalized_string(request->remote_endpoint().address());
    BOOST_LOG(info) << "Web UI: ["sv << address << "] -- redirecting"sv;
    const SimpleWeb::CaseInsensitiveMultimap headers {
      {"Location", path},
      {"X-Frame-Options", "DENY"},
      {"Content-Security-Policy", "frame-ancestors 'none';"}
    };
    response->write(SimpleWeb::StatusCode::redirection_temporary_redirect, headers);
  }

  /**
   * @brief Retrieve the value of a key from a cookie string.
   * @param cookieString The cookie header string.
   * @param key The key to search.
   * @return The value if found, empty string otherwise.
   */
  std::string getCookieValue(const std::string& cookieString, const std::string& key) {
    std::string keyWithEqual = key + "=";
    std::size_t startPos = cookieString.find(keyWithEqual);
    if (startPos == std::string::npos)
      return "";
    startPos += keyWithEqual.length();
    std::size_t endPos = cookieString.find(";", startPos);
    if (endPos == std::string::npos)
      return cookieString.substr(startPos);
    return cookieString.substr(startPos, endPos - startPos);
  }

  /**
   * @brief Check if the IP origin is allowed.
   * @param response The HTTP response object.
   * @param request The HTTP request object.
   * @return True if allowed, false otherwise.
   */
  bool checkAdminOrigin(resp_https_t response, req_https_t request) {
    auto address = net::addr_to_normalized_string(request->remote_endpoint().address());
    auto ip_type = net::from_address(address);
    if (ip_type > shadow_http_common::origin_admin_allowed) {
      BOOST_LOG(info) << "Admin UI: ["sv << address << "] -- denied"sv;
      response->write(SimpleWeb::StatusCode::client_error_forbidden);
      return false;
    }
    return true;
  }

  /**
   * @brief Authenticate the request.
   * @param response The HTTP response object.
   * @param request The HTTP request object.
   * @param needsRedirect Whether to redirect on failure.
   * @return True if authenticated, false otherwise.
   *
   * This function uses session cookies (if set) and ensures they have not expired.
   */
  bool authenticate(resp_https_t response, req_https_t request, bool needsRedirect = false) {
    if (!checkAdminOrigin(response, request))
      return false;
    // If credentials not set, redirect to welcome.
    if (config::runtime.username.empty()) {
      send_redirect(response, request, "/welcome");
      return false;
    }
    // Guard: on failure, redirect if requested.
    auto fg = util::fail_guard([&]() {
      if (needsRedirect) {
        std::string redir_path = "/login?redir=.";
        redir_path += request->path;
        send_redirect(response, request, redir_path.c_str());
      } else {
        send_unauthorized(response, request);
      }
    });
    if (sessionCookie.empty())
      return false;
    // Check for expiry
    if (std::chrono::steady_clock::now() - cookie_creation_time > SESSION_EXPIRE_DURATION) {
      sessionCookie.clear();
      return false;
    }
    auto cookies = request->header.find("cookie");
    if (cookies == request->header.end())
      return false;
    auto authCookie = getCookieValue(cookies->second, "auth");
    if (authCookie.empty() ||
        util::hex(crypto::hash(authCookie + config::runtime.salt)).to_string() != sessionCookie)
      return false;
    fg.disable();
    return true;
  }

  /**
   * @brief Send a 404 Not Found response.
   * @param response The HTTP response object.
   * @param request The HTTP request object.
   */
  void not_found(resp_https_t response, [[maybe_unused]] req_https_t request) {
    constexpr SimpleWeb::StatusCode code = SimpleWeb::StatusCode::client_error_not_found;
    nlohmann::json tree;
    tree["status_code"] = static_cast<int>(code);
    tree["error"] = "Not Found";
    SimpleWeb::CaseInsensitiveMultimap headers;
    headers.emplace("Content-Type", "application/json");
    headers.emplace("X-Frame-Options", "DENY");
    headers.emplace("Content-Security-Policy", "frame-ancestors 'none';");

    response->write(code, tree.dump(), headers);
  }

  /**
   * @brief Send a 400 Bad Request response.
   * @param response The HTTP response object.
   * @param request The HTTP request object.
   * @param error_message The error message.
   */
  void bad_request(resp_https_t response, [[maybe_unused]] req_https_t request, const std::string &error_message = "Bad Request") {
    constexpr SimpleWeb::StatusCode code = SimpleWeb::StatusCode::client_error_bad_request;
    nlohmann::json tree;
    tree["status_code"] = static_cast<int>(code);
    tree["status"] = false;
    tree["error"] = error_message;
    SimpleWeb::CaseInsensitiveMultimap headers;
    headers.emplace("Content-Type", "application/json");
    headers.emplace("X-Frame-Options", "DENY");
    headers.emplace("Content-Security-Policy", "frame-ancestors 'none';");

    response->write(code, tree.dump(), headers);
  }


  /**
   * @brief Validate the request content type and send bad request when mismatch.
   * @param response The HTTP response object.
   * @param request The HTTP request object.
   * @param contentType The required content type.
   */
  bool validateContentType(resp_https_t response, req_https_t request, const std::string_view& contentType) {
    auto requestContentType = request->header.find("content-type");
    if (requestContentType == request->header.end()) {
      bad_request(response, request, "Content type not provided");
      return false;
    }

    // Extract the media type part before any parameters (e.g., charset)
    std::string actualContentType = requestContentType->second;
    size_t semicolonPos = actualContentType.find(';');
    if (semicolonPos != std::string::npos) {
      actualContentType = actualContentType.substr(0, semicolonPos);
    }

    // Trim whitespace and convert to lowercase for case-insensitive comparison
    boost::algorithm::trim(actualContentType);
    boost::algorithm::to_lower(actualContentType);

    std::string expectedContentType(contentType);
    boost::algorithm::to_lower(expectedContentType);

    if (actualContentType != expectedContentType) {
      bad_request(response, request, "Content type mismatch");
      return false;
    }
    return true;

    return true;
  }

  /**
   * @brief Get the index page.
   * @param response The HTTP response object.
   * @param request The HTTP request object.
   */
  void getIndexPage(resp_https_t response, req_https_t request) {
    if (!authenticate(response, request, true)) {
      return;
    }

    print_req(request);

    std::string content = file_handler::read_file(WEB_DIR "index.html");
    SimpleWeb::CaseInsensitiveMultimap headers;
    headers.emplace("Content-Type", "text/html; charset=utf-8");
    headers.emplace("X-Frame-Options", "DENY");
    headers.emplace("Content-Security-Policy", "frame-ancestors 'none';");
    response->write(content, headers);
  }

  /**
   * @brief Get the pairing approval page.
   * @param response The HTTP response object.
   * @param request The HTTP request object.
   */
  void getPairingPage(resp_https_t response, req_https_t request) {
    if (!authenticate(response, request, true)) {
      return;
    }

    print_req(request);

    std::string content = file_handler::read_file(WEB_DIR "pairing.html");
    SimpleWeb::CaseInsensitiveMultimap headers;
    headers.emplace("Content-Type", "text/html; charset=utf-8");
    headers.emplace("X-Frame-Options", "DENY");
    headers.emplace("Content-Security-Policy", "frame-ancestors 'none';");
    response->write(content, headers);
  }

  /**
   * @brief Get the apps page.
   * @param response The HTTP response object.
   * @param request The HTTP request object.
   */
  void getAppsPage(resp_https_t response, req_https_t request) {
    if (!authenticate(response, request, true)) {
      return;
    }

    print_req(request);

    std::string content = file_handler::read_file(WEB_DIR "apps.html");
    SimpleWeb::CaseInsensitiveMultimap headers;
    headers.emplace("Content-Type", "text/html; charset=utf-8");
    headers.emplace("X-Frame-Options", "DENY");
    headers.emplace("Content-Security-Policy", "frame-ancestors 'none';");
    headers.emplace("Access-Control-Allow-Origin", "https://images.igdb.com/");
    response->write(content, headers);
  }

  /**
   * @brief Get the clients page.
   * @param response The HTTP response object.
   * @param request The HTTP request object.
   */
  void getClientsPage(resp_https_t response, req_https_t request) {
    if (!authenticate(response, request, true)) {
      return;
    }

    print_req(request);

    std::string content = file_handler::read_file(WEB_DIR "clients.html");
    SimpleWeb::CaseInsensitiveMultimap headers;
    headers.emplace("Content-Type", "text/html; charset=utf-8");
    headers.emplace("X-Frame-Options", "DENY");
    headers.emplace("Content-Security-Policy", "frame-ancestors 'none';");
    response->write(content, headers);
  }

  /**
   * @brief Get the configuration page.
   * @param response The HTTP response object.
   * @param request The HTTP request object.
   */
  void getConfigPage(resp_https_t response, req_https_t request) {
    if (!authenticate(response, request, true)) {
      return;
    }

    print_req(request);

    std::string content = file_handler::read_file(WEB_DIR "config.html");
    SimpleWeb::CaseInsensitiveMultimap headers;
    headers.emplace("Content-Type", "text/html; charset=utf-8");
    headers.emplace("X-Frame-Options", "DENY");
    headers.emplace("Content-Security-Policy", "frame-ancestors 'none';");
    response->write(content, headers);
  }

  /**
   * @brief Get the password page.
   * @param response The HTTP response object.
   * @param request The HTTP request object.
   */
  void getPasswordPage(resp_https_t response, req_https_t request) {
    if (!authenticate(response, request, true)) {
      return;
    }

    print_req(request);

    std::string content = file_handler::read_file(WEB_DIR "password.html");
    SimpleWeb::CaseInsensitiveMultimap headers;
    headers.emplace("Content-Type", "text/html; charset=utf-8");
    headers.emplace("X-Frame-Options", "DENY");
    headers.emplace("Content-Security-Policy", "frame-ancestors 'none';");
    response->write(content, headers);
  }

  /**
   * @brief Get the login page.
   * @param response The HTTP response object.
   * @param request The HTTP request object.
   *
   * @todo Combine this function with getWelcomePage if appropriate.
   */
  void getLoginPage(resp_https_t response, req_https_t request) {
    if (!checkAdminOrigin(response, request)) {
      return;
    }

    if (config::runtime.username.empty()) {
      send_redirect(response, request, "/welcome");
      return;
    }

    std::string content = file_handler::read_file(WEB_DIR "login.html");
    SimpleWeb::CaseInsensitiveMultimap headers;
    headers.emplace("Content-Type", "text/html; charset=utf-8");
    headers.emplace("X-Frame-Options", "DENY");
    headers.emplace("Content-Security-Policy", "frame-ancestors 'none';");
    response->write(content, headers);
  }

  /**
   * @brief Get the welcome page.
   * @param response The HTTP response object.
   * @param request The HTTP request object.
   */
  void getWelcomePage(resp_https_t response, req_https_t request) {
    print_req(request);

    if (!config::runtime.username.empty()) {
      send_redirect(response, request, "/");
      return;
    }

    std::string content = file_handler::read_file(WEB_DIR "welcome.html");
    SimpleWeb::CaseInsensitiveMultimap headers;
    headers.emplace("Content-Type", "text/html; charset=utf-8");
    headers.emplace("X-Frame-Options", "DENY");
    headers.emplace("Content-Security-Policy", "frame-ancestors 'none';");
    response->write(content, headers);
  }

  /**
   * @brief Get the troubleshooting page.
   * @param response The HTTP response object.
   * @param request The HTTP request object.
   */
  void getTroubleshootingPage(resp_https_t response, req_https_t request) {
    if (!authenticate(response, request, true)) {
      return;
    }

    print_req(request);

    std::string content = file_handler::read_file(WEB_DIR "troubleshooting.html");
    SimpleWeb::CaseInsensitiveMultimap headers;
    headers.emplace("Content-Type", "text/html; charset=utf-8");
    headers.emplace("X-Frame-Options", "DENY");
    headers.emplace("Content-Security-Policy", "frame-ancestors 'none';");
    response->write(content, headers);
  }

  /**
   * @brief Get the favicon image.
   * @param response The HTTP response object.
   * @param request The HTTP request object.
   */
  void getFaviconImage(resp_https_t response, req_https_t request) {
    print_req(request);

    std::ifstream in(WEB_DIR "images/lumen.ico", std::ios::binary);
    SimpleWeb::CaseInsensitiveMultimap headers;
    headers.emplace("Content-Type", "image/x-icon");
    headers.emplace("X-Frame-Options", "DENY");
    headers.emplace("Content-Security-Policy", "frame-ancestors 'none';");
    response->write(SimpleWeb::StatusCode::success_ok, in, headers);
  }

  /**
   * @brief Get the Lumen logo image.
   * @param response The HTTP response object.
   * @param request The HTTP request object.
   *
   * @todo combine function with getFaviconImage and possibly getNodeModules
   * @todo use mime_types map
   */
  void getLumenLogoImage(resp_https_t response, req_https_t request) {
    print_req(request);

    std::ifstream in(WEB_DIR "images/logo-lumen-45.png", std::ios::binary);
    SimpleWeb::CaseInsensitiveMultimap headers;
    headers.emplace("Content-Type", "image/png");
    headers.emplace("X-Frame-Options", "DENY");
    headers.emplace("Content-Security-Policy", "frame-ancestors 'none';");
    response->write(SimpleWeb::StatusCode::success_ok, in, headers);
  }

  /**
   * @brief Check if a path is a child of another path.
   * @param base The base path.
   * @param query The path to check.
   * @return True if the path is a child of the base path, false otherwise.
   */
  bool isChildPath(fs::path const &base, fs::path const &query) {
    auto relPath = fs::relative(base, query);
    return *(relPath.begin()) != fs::path("..");
  }

  /**
   * @brief Get an asset from the node_modules directory.
   * @param response The HTTP response object.
   * @param request The HTTP request object.
   */
  void getNodeModules(resp_https_t response, req_https_t request) {
    print_req(request);

    fs::path webDirPath(WEB_DIR);
    fs::path nodeModulesPath(webDirPath / "assets");

    // .relative_path is needed to shed any leading slash that might exist in the request path
    auto filePath = fs::weakly_canonical(webDirPath / fs::path(request->path).relative_path());

    // Don't do anything if file does not exist or is outside the assets directory
    if (!isChildPath(filePath, nodeModulesPath)) {
      BOOST_LOG(warning) << "Someone requested a path " << filePath << " that is outside the assets folder";
      bad_request(response, request);
      return;
    }

    if (!fs::exists(filePath)) {
      not_found(response, request);
      return;
    }

    auto relPath = fs::relative(filePath, webDirPath);
    // get the mime type from the file extension mime_types map
    // remove the leading period from the extension
    auto mimeType = mime_types.find(relPath.extension().string().substr(1));
    if (mimeType == mime_types.end()) {
      bad_request(response, request);
      return;
    }
    SimpleWeb::CaseInsensitiveMultimap headers;
    headers.emplace("Content-Type", mimeType->second);
    headers.emplace("X-Frame-Options", "DENY");
    headers.emplace("Content-Security-Policy", "frame-ancestors 'none';");
    std::ifstream in(filePath.string(), std::ios::binary);
    response->write(SimpleWeb::StatusCode::success_ok, in, headers);
  }

  /**
   * @brief Get the list of available applications.
   * @param response The HTTP response object.
   * @param request The HTTP request object.
   *
   * @api_examples{/api/apps| GET| null}
   */
  void getApps(resp_https_t response, req_https_t request) {
    if (!authenticate(response, request)) {
      return;
    }

    print_req(request);

    try {
      std::string content = file_handler::read_file(config::stream.file_apps.c_str());
      nlohmann::json file_tree = nlohmann::json::parse(content);

      file_tree["current_app"] = proc::proc.get_running_app_uuid();
      file_tree["host_uuid"] = shadow_http_common::unique_id;
      file_tree["host_name"] = config::shadow_http.host_name;

      send_response(response, file_tree);
    } catch (std::exception &e) {
      BOOST_LOG(warning) << "GetApps: "sv << e.what();
      bad_request(response, request, e.what());
    }
  }

  /**
   * @brief Save an application. To save a new application the UUID must be empty.
   *        To update an existing application, you must provide the current UUID of the application.
   * @param response The HTTP response object.
   * @param request The HTTP request object.
   * The body for the post request should be JSON serialized in the following format:
   * @code{.json}
   * {
   *   "name": "Application Name",
   *   "output": "Log Output Path",
   *   "cmd": "Command to run the application",
   *   "exclude-global-prep-cmd": false,
   *   "elevated": false,
   *   "auto-detach": true,
   *   "wait-all": true,
   *   "exit-timeout": 5,
   *   "prep-cmd": [
   *     {
   *       "do": "Command to prepare",
   *       "undo": "Command to undo preparation",
   *       "elevated": false
   *     }
   *   ],
   *   "detached": [
   *     "Detached command"
   *   ],
   *   "image-path": "Full path to the application image. Must be a png file.",
   *   "uuid": "aaaa-bbbb"
   * }
   * @endcode
   *
   * @api_examples{/api/apps| POST| {"name":"Hello, World!","uuid": "aaaa-bbbb"}}
   */
  void saveApp(resp_https_t response, req_https_t request) {
    if (!validateContentType(response, request, "application/json") || !authenticate(response, request)) {
      return;
    }

    print_req(request);

    std::stringstream ss;
    ss << request->content.rdbuf();

    BOOST_LOG(info) << config::stream.file_apps;
    try {
      // TODO: Input Validation

      // Read the input JSON from the request body.
      nlohmann::json inputTree = nlohmann::json::parse(ss.str());

      // Read the existing apps file.
      std::string content = file_handler::read_file(config::stream.file_apps.c_str());
      nlohmann::json fileTree = nlohmann::json::parse(content);

      // Migrate/merge the new app into the file tree.
      proc::migrate_apps(&fileTree, &inputTree);

      // Write the updated file tree back to disk.
      file_handler::write_file(config::stream.file_apps.c_str(), fileTree.dump(4));
      proc::refresh(config::stream.file_apps);

      // Prepare and send the output response.
      nlohmann::json outputTree;
      outputTree["status"] = true;
      send_response(response, outputTree);
    }
    catch (std::exception &e) {
      BOOST_LOG(warning) << "SaveApp: "sv << e.what();
      bad_request(response, request, e.what());
    }
  }

  /**
   * @brief Close the currently running application.
   * @param response The HTTP response object.
   * @param request The HTTP request object.
   *
   * @api_examples{/api/apps/close| POST| null}
   */
  void closeApp(resp_https_t response, req_https_t request) {
    if (!validateContentType(response, request, "application/json") || !authenticate(response, request)) {
      return;
    }

    print_req(request);

    proc::proc.terminate();
    nlohmann::json output_tree;
    output_tree["status"] = true;
    send_response(response, output_tree);
  }

  /**
   * @brief Reorder applications.
   * @param response The HTTP response object.
   * @param request The HTTP request object.
   *
   * @api_examples{/api/apps/reorder| POST| {"order": ["aaaa-bbbb", "cccc-dddd"]}}
   */
  void reorderApps(resp_https_t response, req_https_t request) {
    if (!validateContentType(response, request, "application/json") || !authenticate(response, request)) {
      return;
    }

    print_req(request);

    try {
      std::stringstream ss;
      ss << request->content.rdbuf();

      nlohmann::json input_tree = nlohmann::json::parse(ss.str());
      nlohmann::json output_tree;

      // Read the existing apps file.
      std::string content = file_handler::read_file(config::stream.file_apps.c_str());
      nlohmann::json fileTree = nlohmann::json::parse(content);

      // Get the desired order of UUIDs from the request.
      if (!input_tree.contains("order") || !input_tree["order"].is_array()) {
        throw std::runtime_error("Missing or invalid 'order' array in request body");
      }
      const auto& order_uuids_json = input_tree["order"];

      // Get the original apps array from the fileTree.
      // Default to an empty array if "apps" key is missing or if it's present but not an array (after logging an error).
      nlohmann::json original_apps_list = nlohmann::json::array();
      if (fileTree.contains("apps")) {
        if (fileTree["apps"].is_array()) {
          original_apps_list = fileTree["apps"];
        } else {
          // "apps" key exists but is not an array. This is a malformed state.
          BOOST_LOG(error) << "ReorderApps: 'apps' key in apps configuration file ('" << config::stream.file_apps
                           << "') is present but not an array.";
          throw std::runtime_error("'apps' in file is not an array, cannot reorder.");
        }
      } else {
        // "apps" key is missing. Treat as an empty list. Reordering an empty list is valid.
        BOOST_LOG(debug) << "ReorderApps: 'apps' key missing in apps configuration file ('" << config::stream.file_apps
                         << "'). Treating as an empty list for reordering.";
        // original_apps_list is already an empty array, so no specific action needed here.
      }

      nlohmann::json reordered_apps_list = nlohmann::json::array();
      std::vector<bool> item_moved(original_apps_list.size(), false);

      // Phase 1: Place apps according to the 'order' array from the request.
      // Iterate through the desired order of UUIDs.
      for (const auto& uuid_json_value : order_uuids_json) {
        if (!uuid_json_value.is_string()) {
          BOOST_LOG(warning) << "ReorderApps: Encountered a non-string UUID in the 'order' array. Skipping this entry.";
          continue;
        }
        std::string target_uuid = uuid_json_value.get<std::string>();
        bool found_match_for_ordered_uuid = false;

        // Find the first unmoved app in the original list that matches the current target_uuid.
        for (size_t i = 0; i < original_apps_list.size(); ++i) {
          if (item_moved[i]) {
            continue; // This specific app object has already been placed.
          }

          const auto& app_item = original_apps_list[i];
          // Ensure the app item is an object and has a UUID to match against.
          if (app_item.is_object() && app_item.contains("uuid") && app_item["uuid"].is_string()) {
            if (app_item["uuid"].get<std::string>() == target_uuid) {
              reordered_apps_list.push_back(app_item); // Add the found app object to the new list.
              item_moved[i] = true;                    // Mark this specific object as moved.
              found_match_for_ordered_uuid = true;
              break; // Found an app for this UUID, move to the next UUID in the 'order' array.
            }
          }
        }

        if (!found_match_for_ordered_uuid) {
          // This means a UUID specified in the 'order' array was not found in the original_apps_list
          // among the currently available (unmoved) app objects.
          // Per instruction "If the uuid is missing from the original json file, omit it."
          BOOST_LOG(debug) << "ReorderApps: UUID '" << target_uuid << "' from 'order' array not found in available apps list or its matching app was already processed. Omitting.";
        }
      }

      // Phase 2: Append any remaining apps from the original list that were not explicitly ordered.
      // These are app objects that were not marked 'item_moved' in Phase 1.
      for (size_t i = 0; i < original_apps_list.size(); ++i) {
        if (!item_moved[i]) {
          reordered_apps_list.push_back(original_apps_list[i]);
        }
      }

      // Update the fileTree with the new, reordered list of apps.
      fileTree["apps"] = reordered_apps_list;

      // Write the modified fileTree back to the apps configuration file.
      file_handler::write_file(config::stream.file_apps.c_str(), fileTree.dump(4));

      // Notify relevant parts of the system that the apps configuration has changed.
      proc::refresh(config::stream.file_apps);

      output_tree["status"] = true;
      send_response(response, output_tree);
    } catch (std::exception &e) {
      BOOST_LOG(warning) << "ReorderApps: "sv << e.what();
      bad_request(response, request, e.what());
    }
  }

  /**
   * @brief Delete an application.
   * @param response The HTTP response object.
   * @param request The HTTP request object.
   *
   * @api_examples{/api/apps/delete | POST| { uuid: 'aaaa-bbbb' }}
   */
  void deleteApp(resp_https_t response, req_https_t request) {
    if (!validateContentType(response, request, "application/json") || !authenticate(response, request)) {
      return;
    }

    print_req(request);

    try {
      std::stringstream ss;
      ss << request->content.rdbuf();
      nlohmann::json input_tree = nlohmann::json::parse(ss.str());

      // Check for required uuid field in body
      if (!input_tree.contains("uuid") || !input_tree["uuid"].is_string()) {
        bad_request(response, request, "Missing or invalid uuid in request body");
        return;
      }
      auto uuid = input_tree["uuid"].get<std::string>();

      // Read the apps file into a nlohmann::json object.
      std::string content = file_handler::read_file(config::stream.file_apps.c_str());
      nlohmann::json fileTree = nlohmann::json::parse(content);

      // Remove any app with the matching uuid directly from the "apps" array.
      if (fileTree.contains("apps") && fileTree["apps"].is_array()) {
        auto& apps = fileTree["apps"];
        apps.erase(
          std::remove_if(apps.begin(), apps.end(), [&uuid](const nlohmann::json& app) {
            return app.value("uuid", "") == uuid;
          }),
          apps.end()
        );
      }

      // Write the updated JSON back to the file.
      file_handler::write_file(config::stream.file_apps.c_str(), fileTree.dump(4));
      proc::refresh(config::stream.file_apps);

      // Prepare and send the response.
      nlohmann::json outputTree;
      outputTree["status"] = true;
      send_response(response, outputTree);
    }
    catch (std::exception &e) {
      BOOST_LOG(warning) << "DeleteApp: "sv << e.what();
      bad_request(response, request, e.what());
    }
  }

  /**
   * @brief Get the list of paired clients.
   * @param response The HTTP response object.
   * @param request The HTTP request object.
   *
   * @api_examples{/api/clients/list| GET| null}
   */
  void getClients(resp_https_t response, req_https_t request) {
    if (!authenticate(response, request)) {
      return;
    }

    print_req(request);

    nlohmann::json named_certs = shadow_http::get_all_clients();
    nlohmann::json output_tree;
    output_tree["named_certs"] = named_certs;
#ifdef _WIN32
    output_tree["platform"] = "windows";
#endif
    output_tree["status"] = true;
    send_response(response, output_tree);
  }

  /**
   * @brief Update client information.
   * @param response The HTTP response object.
   * @param request The HTTP request object.
   *
   * The body for the POST request should be JSON serialized in the following format:
   * @code{.json}
   * {
   *   "uuid": "<uuid>",
   *   "name": "<Friendly Name>",
   *   "display_mode": "1920x1080x59.94",
   *   "do": [ { "cmd": "<command>", "elevated": false }, ... ],
   *   "undo": [ { "cmd": "<command>", "elevated": false }, ... ],
   *   "perm": <uint32_t>
   * }
   * @endcode
   */
  void updateClient(resp_https_t response, req_https_t request) {
    if (!validateContentType(response, request, "application/json") || !authenticate(response, request)) {
      return;
    }

    print_req(request);

    std::stringstream ss;
    ss << request->content.rdbuf();
    try {
      nlohmann::json input_tree = nlohmann::json::parse(ss.str());
      nlohmann::json output_tree;
      std::string uuid = input_tree.value("uuid", "");
      std::string name = input_tree.value("name", "");
      std::string display_mode = input_tree.value("display_mode", "");
      bool allow_client_commands = input_tree.value("allow_client_commands", true);
      bool always_use_virtual_display = input_tree.value("always_use_virtual_display", false);
      auto do_cmds = shadow_http::extract_command_entries(input_tree, "do");
      auto undo_cmds = shadow_http::extract_command_entries(input_tree, "undo");
      auto perm = static_cast<crypto::PERM>(input_tree.value("perm", static_cast<uint32_t>(crypto::PERM::_no)) & static_cast<uint32_t>(crypto::PERM::_all));
      output_tree["status"] = shadow_http::update_device_info(
        uuid,
        name,
        display_mode,
        do_cmds,
        undo_cmds,
        perm,
        allow_client_commands,
        always_use_virtual_display
      );
      send_response(response, output_tree);
    } catch (std::exception &e) {
      BOOST_LOG(warning) << "Update Client: "sv << e.what();
      bad_request(response, request, e.what());
    }
  }

  /**
   * @brief Unpair a client.
   * @param response The HTTP response object.
   * @param request The HTTP request object.
   *
   * The body for the POST request should be JSON serialized in the following format:
   * @code{.json}
   * {
   *  "uuid": "<uuid>"
   * }
   * @endcode
   *
   * @api_examples{/api/clients/unpair| POST| {"uuid":"1234"}}
   */
  void unpair(resp_https_t response, req_https_t request) {
    if (!validateContentType(response, request, "application/json") || !authenticate(response, request)) {
      return;
    }

    print_req(request);

    std::stringstream ss;
    ss << request->content.rdbuf();
    try {
      nlohmann::json input_tree = nlohmann::json::parse(ss.str());
      nlohmann::json output_tree;
      std::string uuid = input_tree.value("uuid", "");
      output_tree["status"] = shadow_http::unpair_client(uuid);
      send_response(response, output_tree);
    } catch (std::exception &e) {
      BOOST_LOG(warning) << "Unpair: "sv << e.what();
      bad_request(response, request, e.what());
    }
  }

  /**
   * @brief Unpair all clients.
   * @param response The HTTP response object.
   * @param request The HTTP request object.
   *
   * @api_examples{/api/clients/unpair-all| POST| null}
   */
  void unpairAll(resp_https_t response, req_https_t request) {
    if (!validateContentType(response, request, "application/json") || !authenticate(response, request)) {
      return;
    }

    print_req(request);

    shadow_http::erase_all_clients();
    proc::proc.terminate();
    nlohmann::json output_tree;
    output_tree["status"] = true;
    send_response(response, output_tree);
  }

  /**
   * @brief Get the configuration settings.
   * @param response The HTTP response object.
   * @param request The HTTP request object.
   */
  void getConfig(resp_https_t response, req_https_t request) {
    if (!authenticate(response, request)) {
      return;
    }

    print_req(request);

    nlohmann::json output_tree;
    output_tree["status"] = true;
    output_tree["platform"] = SUNSHINE_PLATFORM;
    output_tree["version"] = PROJECT_VERSION;
#ifdef _WIN32
    output_tree["vdisplayStatus"] = (int)proc::vDisplayDriverStatus;
#endif
    auto vars = config::parse_config(file_handler::read_file(config::runtime.config_file.c_str()));
    for (auto &[name, value] : vars) {
      output_tree[name] = value;
    }
    send_response(response, output_tree);
  }

  /**
   * @brief Get the locale setting.
   * @param response The HTTP response object.
   * @param request The HTTP request object.
   *
   * @api_examples{/api/configLocale| GET| null}
   */
  void getLocale(resp_https_t response, req_https_t request) {
    print_req(request);

    nlohmann::json output_tree;
    output_tree["status"] = true;
    output_tree["locale"] = config::runtime.locale;
    send_response(response, output_tree);
  }

  /**
   * @brief Save the configuration settings.
   * @param response The HTTP response object.
   * @param request The HTTP request object.
   * The body for the post request should be JSON serialized in the following format:
   * @code{.json}
   * {
   *   "key": "value"
   * }
   * @endcode
   *
   * @attention{It is recommended to ONLY save the config settings that differ from the default behavior.}
   *
   * @api_examples{/api/config| POST| {"key":"value"}}
   */
  void saveConfig(resp_https_t response, req_https_t request) {
    if (!validateContentType(response, request, "application/json") || !authenticate(response, request)) {
      return;
    }

    print_req(request);

    std::stringstream ss;
    ss << request->content.rdbuf();
    try {
      // TODO: Input Validation
      std::stringstream config_stream;
      nlohmann::json output_tree;
      nlohmann::json input_tree = nlohmann::json::parse(ss);
      for (const auto &[k, v] : input_tree.items()) {
        if (v.is_null() || (v.is_string() && v.get<std::string>().empty())) {
          continue;
        }

        // v.dump() will dump valid json, which we do not want for strings in the config right now
        // we should migrate the config file to straight json and get rid of all this nonsense
        config_stream << k << " = " << (v.is_string() ? v.get<std::string>() : v.dump()) << std::endl;
      }
      file_handler::write_file(config::runtime.config_file.c_str(), config_stream.str());
      output_tree["status"] = true;
      send_response(response, output_tree);
    } catch (std::exception &e) {
      BOOST_LOG(warning) << "SaveConfig: "sv << e.what();
      bad_request(response, request, e.what());
    }
  }

  /**
   * @brief Upload a cover image.
   * @param response The HTTP response object.
   * @param request The HTTP request object.
   *
   * @api_examples{/api/covers/upload| POST| {"key":"igdb_1234","url":"https://images.igdb.com/igdb/image/upload/t_cover_big_2x/abc123.png"}}
   */
  void uploadCover(resp_https_t response, req_https_t request) {
    if (!validateContentType(response, request, "application/json") || !authenticate(response, request)) {
      return;
    }

    std::stringstream ss;

    ss << request->content.rdbuf();
    try {
      nlohmann::json input_tree = nlohmann::json::parse(ss.str());
      nlohmann::json output_tree;
      std::string key = input_tree.value("key", "");
      if (key.empty()) {
        bad_request(response, request, "Cover key is required");
        return;
      }
      std::string url = input_tree.value("url", "");
      const std::string coverdir = platf::appdata().string() + "/covers/";
      file_handler::make_directory(coverdir);
      std::string path = coverdir + shadow_http_common::url_escape(key) + ".png";
      if (!url.empty()) {
        if (shadow_http_common::url_get_host(url) != "images.igdb.com") {
          bad_request(response, request, "Only images.igdb.com is allowed");
          return;
        }
        if (!shadow_http_common::download_file(url, path)) {
          bad_request(response, request, "Failed to download cover");
          return;
        }
      } else {
        auto data = SimpleWeb::Crypto::Base64::decode(input_tree.value("data", ""));
        std::ofstream imgfile(path);
        imgfile.write(data.data(), static_cast<int>(data.size()));
      }
      output_tree["status"] = true;
      output_tree["path"] = path;
      send_response(response, output_tree);
    } catch (std::exception &e) {
      BOOST_LOG(warning) << "UploadCover: "sv << e.what();
      bad_request(response, request, e.what());
    }
  }

  /**
   * @brief Get the logs from the log file.
   * @param response The HTTP response object.
   * @param request The HTTP request object.
   *
   * @api_examples{/api/logs| GET| null}
   */
  void getLogs(resp_https_t response, req_https_t request) {
    if (!authenticate(response, request)) {
      return;
    }

    print_req(request);
    std::string content = file_handler::read_file(config::runtime.log_file.c_str());
    SimpleWeb::CaseInsensitiveMultimap headers;
    std::string contentType = "text/plain";
  #ifdef _WIN32
    contentType += "; charset=";
    contentType += currentCodePageToCharset();
  #endif
    headers.emplace("Content-Type", contentType);
    headers.emplace("X-Frame-Options", "DENY");
    headers.emplace("Content-Security-Policy", "frame-ancestors 'none';");
    response->write(SimpleWeb::StatusCode::success_ok, content, headers);
  }

  /**
   * @brief Update existing credentials.
   * @param response The HTTP response object.
   * @param request The HTTP request object.
   *
   * The body for the POST request should be JSON serialized in the following format:
   * @code{.json}
   * {
   *   "currentUsername": "Current Username",
   *   "currentPassword": "Current Password",
   *   "newUsername": "New Username",
   *   "newPassword": "New Password",
   *   "confirmNewPassword": "Confirm New Password"
   * }
   * @endcode
   *
   * @api_examples{/api/password| POST| {"currentUsername":"admin","currentPassword":"admin","newUsername":"admin","newPassword":"admin","confirmNewPassword":"admin"}}
   */
  void savePassword(resp_https_t response, req_https_t request) {
    if ((!config::runtime.username.empty() && !authenticate(response, request)) || !validateContentType(response, request, "application/json"))
      return;
    print_req(request);
    std::vector<std::string> errors;
    std::stringstream ss;
    ss << request->content.rdbuf();
    try {
      nlohmann::json input_tree = nlohmann::json::parse(ss.str());
      nlohmann::json output_tree;
      std::string username = input_tree.value("currentUsername", "");
      std::string newUsername = input_tree.value("newUsername", "");
      std::string password = input_tree.value("currentPassword", "");
      std::string newPassword = input_tree.value("newPassword", "");
      std::string confirmPassword = input_tree.value("confirmNewPassword", "");
      if (newUsername.empty())
        newUsername = username;
      if (newUsername.empty()) {
        errors.push_back("Invalid Username");
      } else {
        auto hash = util::hex(crypto::hash(password + config::runtime.salt)).to_string();
        if (config::runtime.username.empty() ||
            (boost::iequals(username, config::runtime.username) && hash == config::runtime.password)) {
          if (newPassword.empty() || newPassword != confirmPassword)
            errors.push_back("Password Mismatch");
          else {
            shadow_http_common::save_user_creds(config::runtime.credentials_file, newUsername, newPassword);
            shadow_http_common::reload_user_creds(config::runtime.credentials_file);
            sessionCookie.clear(); // force re-login
            output_tree["status"] = true;
          }
        } else {
          errors.push_back("Invalid Current Credentials");
        }
      }
      if (!errors.empty()) {
        std::string error = std::accumulate(errors.begin(), errors.end(), std::string(),
                                              [](const std::string &a, const std::string &b) {
                                                return a.empty() ? b : a + ", " + b;
                                              });
        bad_request(response, request, error);
        return;
      }
      send_response(response, output_tree);
    } catch (std::exception &e) {
      BOOST_LOG(warning) << "SavePassword: "sv << e.what();
      bad_request(response, request, e.what());
    }
  }

  /**
   * @brief Start a Shadow-native pairing request for a device.
   * @param response The HTTP response object.
   * @param request The HTTP request object.
   */
  void startShadowPairing(resp_https_t response, req_https_t request) {
    if (!validateContentType(response, request, "application/json")) {
      return;
    }

    print_req(request);

    try {
      std::stringstream ss;
      ss << request->content.rdbuf();
      nlohmann::json input_tree = nlohmann::json::parse(ss.str());

      auto pairing_request = create_pairing_request(
        input_tree.value("deviceName", "Unnamed Device"),
        input_tree.value("platform", "unknown"),
        input_tree.value("clientId", ""),
        input_tree.value("clientCertificate", "")
      );

      nlohmann::json output_tree;
      output_tree["status"] = true;
      output_tree["pairing"] = {
        {"pairingId", pairing_request.pairing_id},
        {"userCode", pairing_request.user_code},
        {"deviceName", pairing_request.device_name},
        {"platform", pairing_request.platform},
        {"clientId", pairing_request.client_id},
        {"trustedClientUuid", pairing_request.trusted_client_uuid},
        {"publicKeyPresent", pairing_request.public_key_present},
        {"clientTrusted", pairing_request.client_trusted},
        {"clientCertificateRequired", pairing_request.client_certificate_required},
        {"status", pairing_request.status},
        {"serverUniqueId", pairing_request.server_unique_id},
        {"serviceType", pairing_request.service_type},
        {"controlHttpsPort", pairing_request.control_https_port},
        {"expiresInSeconds", pairing_request.expires_in_seconds},
        {"pollIntervalSeconds", pairing_request.poll_interval_seconds}
      };
      append_shadow_pairing_host_details(output_tree["pairing"], request);
      send_response(response, output_tree);
    } catch (std::exception &e) {
      BOOST_LOG(warning) << "StartShadowPairing: "sv << e.what();
      bad_request(response, request, e.what());
    }
  }

  /**
   * @brief Get the current status of a Shadow-native pairing request.
   * @param response The HTTP response object.
   * @param request The HTTP request object.
   */
  void getShadowPairingStatus(resp_https_t response, req_https_t request) {
    print_req(request);

    auto args = request->parse_query_string();
    auto pairing_id_it = args.find("pairingId"s);
    if (pairing_id_it == args.end()) {
      bad_request(response, request, "Missing pairingId query parameter");
      return;
    }

    std::optional<shadow_pairing_request_t> pairing_request;
    {
      std::lock_guard lock {shadow_pairing_requests_mutex};
      erase_expired_shadow_pairing_requests_locked();
      auto it = shadow_pairing_requests.find(pairing_id_it->second);
      if (it != shadow_pairing_requests.end()) {
        pairing_request = it->second;
      }
    }

    if (!pairing_request) {
      not_found(response, request);
      return;
    }

    nlohmann::json output_tree;
    output_tree["status"] = true;
    output_tree["pairing"] = serialize_shadow_pairing_request(*pairing_request);
    append_shadow_pairing_host_details(output_tree["pairing"], request);
    send_response(response, output_tree);
  }

  /**
   * @brief List pending and decided Shadow pairing requests for the Web UI.
   * @param response The HTTP response object.
   * @param request The HTTP request object.
   */
  void listShadowPairingRequests(resp_https_t response, req_https_t request) {
    if (!authenticate(response, request)) {
      return;
    }

    print_req(request);

    nlohmann::json requests_json = nlohmann::json::array();
    {
      std::lock_guard lock {shadow_pairing_requests_mutex};
      erase_expired_shadow_pairing_requests_locked();
      for (const auto &[_, pairing_request] : shadow_pairing_requests) {
        requests_json.push_back(serialize_shadow_pairing_request(pairing_request));
      }
    }

    nlohmann::json output_tree;
    output_tree["status"] = true;
    output_tree["requests"] = requests_json;
    send_response(response, output_tree);
  }

  /**
   * @brief Approve or reject a Shadow pairing request.
   * @param response The HTTP response object.
   * @param request The HTTP request object.
   * @param approved Whether the pairing request should be approved.
   */
  void setShadowPairingDecision(resp_https_t response, req_https_t request, bool approved) {
    if (!validateContentType(response, request, "application/json") || !authenticate(response, request)) {
      return;
    }

    print_req(request);

    try {
      std::stringstream ss;
      ss << request->content.rdbuf();
      nlohmann::json input_tree = nlohmann::json::parse(ss.str());

      std::optional<std::string> pairing_id;
      std::optional<shadow_pairing_request_t> pairing_request;
      {
        std::lock_guard lock {shadow_pairing_requests_mutex};
        erase_expired_shadow_pairing_requests_locked();
        pairing_id = resolve_shadow_pairing_request_id(input_tree, shadow_pairing_requests);
        if (!pairing_id) {
          not_found(response, request);
          return;
        }

        pairing_request = shadow_pairing_requests[*pairing_id];
      }

      if (approved) {
        shadow_http::authorize_client_certificate_result_t authorize_result;
        auto authorize_error = shadow_http::authorize_client_certificate(
          pairing_request->device_name,
          pairing_request->client_id,
          pairing_request->public_key,
          &authorize_result
        );
        if (authorize_error) {
          BOOST_LOG(warning) << "Shadow pairing request ["sv << pairing_request->pairing_id
                             << "] could not be trusted: "sv << *authorize_error;
          bad_request(response, request, *authorize_error);
          return;
        }

        pairing_request->trusted_client_uuid = authorize_result.uuid;
        pairing_request->client_id = authorize_result.uuid;
        pairing_request->device_name = authorize_result.name;
        pairing_request->client_trusted = true;
      }

      {
        std::lock_guard lock {shadow_pairing_requests_mutex};
        erase_expired_shadow_pairing_requests_locked();

        auto it = shadow_pairing_requests.find(*pairing_id);
        if (it == shadow_pairing_requests.end()) {
          not_found(response, request);
          return;
        }

        it->second.device_name = pairing_request->device_name;
        it->second.client_id = pairing_request->client_id;
        it->second.trusted_client_uuid = pairing_request->trusted_client_uuid;
        it->second.client_trusted = pairing_request->client_trusted;
        it->second.status = approved ? shadow_pairing_status_e::approved : shadow_pairing_status_e::rejected;
        pairing_request = it->second;
      }

      BOOST_LOG(info) << "Shadow pairing request ["sv << pairing_request->pairing_id << "] "
                      << (approved ? "approved"sv : "rejected"sv);

      nlohmann::json output_tree;
      output_tree["status"] = true;
      output_tree["pairing"] = serialize_shadow_pairing_request(*pairing_request);
      send_response(response, output_tree);
    } catch (std::exception &e) {
      BOOST_LOG(warning) << "SetShadowPairingDecision: "sv << e.what();
      bad_request(response, request, e.what());
    }
  }

  void approveShadowPairing(resp_https_t response, req_https_t request) {
    setShadowPairingDecision(response, request, true);
  }

  void rejectShadowPairing(resp_https_t response, req_https_t request) {
    setShadowPairingDecision(response, request, false);
  }

  /**
   * @brief Reset the display device persistence.
   * @param response The HTTP response object.
   * @param request The HTTP request object.
   *
   * @api_examples{/api/reset-display-device-persistence| POST| null}
   */
  void resetDisplayDevicePersistence(resp_https_t response, req_https_t request) {
    if (!validateContentType(response, request, "application/json") || !authenticate(response, request)) {
      return;
    }

    print_req(request);

    nlohmann::json output_tree;
    output_tree["status"] = display_device::reset_persistence();
    send_response(response, output_tree);
  }

  /**
   * @brief Restart Lumen.
   * @param response The HTTP response object.
   * @param request The HTTP request object.
   *
   * @api_examples{/api/restart| POST| null}
   */
  void restart(resp_https_t response, req_https_t request) {
    if (!validateContentType(response, request, "application/json") || !authenticate(response, request)) {
      return;
    }

    print_req(request);
    nlohmann::json output_tree;
    output_tree["status"] = true;
    send_response(response, output_tree);

    std::thread([]() {
      std::this_thread::sleep_for(std::chrono::milliseconds(100));
      platf::restart();
    }).detach();
  }

  /**
   * @brief Quit Lumen.
   * @param response The HTTP response object.
   * @param request The HTTP request object.
   *
   * On Windows, if running in a service, a special shutdown code is returned.
   */
  void quit(resp_https_t response, req_https_t request) {
    if (!authenticate(response, request)) {
      return;
    }

    print_req(request);

    BOOST_LOG(warning) << "Requested quit from config page!"sv;

    proc::proc.terminate();

#ifdef _WIN32
    if (GetConsoleWindow() == NULL) {
      lifetime::exit_runtime(ERROR_SHUTDOWN_IN_PROGRESS, true);
    } else
#endif
    {
      lifetime::exit_runtime(0, true);
    }
    // If exit fails, write a response after 5 seconds.
    std::thread write_resp([response]{
      std::this_thread::sleep_for(5s);
      response->write();
    });
    write_resp.detach();
  }

  /**
   * @brief Launch an application.
   * @param response The HTTP response object.
   * @param request The HTTP request object.
   */
  void launchApp(resp_https_t response, req_https_t request) {
    if (!validateContentType(response, request, "application/json") || !authenticate(response, request)) {
      return;
    }

    print_req(request);

    try {
      std::stringstream ss;
      ss << request->content.rdbuf();
      nlohmann::json input_tree = nlohmann::json::parse(ss.str());

      // Check for required uuid field in body
      if (!input_tree.contains("uuid") || !input_tree["uuid"].is_string()) {
        bad_request(response, request, "Missing or invalid uuid in request body");
        return;
      }
      std::string uuid = input_tree["uuid"].get<std::string>();

      nlohmann::json output_tree;
      const auto &apps = proc::proc.get_apps();
      for (auto &app : apps) {
        if (app.uuid == uuid) {
          crypto::named_cert_t named_cert {
            .name = "",
            .uuid = shadow_http_common::unique_id,
            .perm = crypto::PERM::_all,
          };
          BOOST_LOG(info) << "Launching app ["sv << app.name << "] from web UI"sv;
          auto launch_session = shadow_http::make_launch_session(true, false, request->parse_query_string(), &named_cert);
          auto err = proc::proc.execute(app, launch_session);
          if (err) {
            bad_request(response, request, err == 503 ?
                        "Failed to initialize video capture/encoding. Is a display connected and turned on?" :
                        "Failed to start the specified application");
          } else {
            output_tree["status"] = true;
            send_response(response, output_tree);
          }
          return;
        }
      }
      BOOST_LOG(error) << "Couldn't find app with uuid ["sv << uuid << ']';
      bad_request(response, request, "Cannot find requested application");
    }
    catch (std::exception &e) {
      BOOST_LOG(warning) << "LaunchApp: "sv << e.what();
      bad_request(response, request, e.what());
    }
  }

  /**
   * @brief Disconnect a client.
   * @param response The HTTP response object.
   * @param request The HTTP request object.
   */
  void disconnect(resp_https_t response, req_https_t request) {
    if (!validateContentType(response, request, "application/json") || !authenticate(response, request)) {
      return;
    }

    print_req(request);

    try {
      std::stringstream ss;
      ss << request->content.rdbuf();
      nlohmann::json output_tree;
      nlohmann::json input_tree = nlohmann::json::parse(ss.str());
      std::string uuid = input_tree.value("uuid", "");
      output_tree["status"] = shadow_http::find_and_stop_session(uuid, true);
      send_response(response, output_tree);
    } catch (std::exception &e) {
      BOOST_LOG(warning) << "Disconnect: "sv << e.what();
      bad_request(response, request, e.what());
    }
  }

  /**
   * @brief Login the user.
   * @param response The HTTP response object.
   * @param request The HTTP request object.
   *
   * The body for the POST request should be JSON serialized in the following format:
   * @code{.json}
   * {
   *   "username": "<username>",
   *   "password": "<password>"
   * }
   * @endcode
   */
  void login(resp_https_t response, req_https_t request) {
    if (!checkAdminOrigin(response, request) || !validateContentType(response, request, "application/json")) {
      return;
    }

    auto fg = util::fail_guard([&]{
      response->write(SimpleWeb::StatusCode::client_error_unauthorized);
    });

    try {
      std::stringstream ss;
      ss << request->content.rdbuf();
      nlohmann::json input_tree = nlohmann::json::parse(ss.str());
      std::string username = input_tree.value("username", "");
      std::string password = input_tree.value("password", "");
      std::string hash = util::hex(crypto::hash(password + config::runtime.salt)).to_string();
      if (!boost::iequals(username, config::runtime.username) || hash != config::runtime.password)
        return;
      std::string sessionCookieRaw = crypto::rand_alphabet(64);
      sessionCookie = util::hex(crypto::hash(sessionCookieRaw + config::runtime.salt)).to_string();
      cookie_creation_time = std::chrono::steady_clock::now();
      const SimpleWeb::CaseInsensitiveMultimap headers {
        { "Set-Cookie", "auth=" + sessionCookieRaw + "; Secure; SameSite=Strict; Max-Age=2592000; Path=/" }
      };
      response->write(headers);
      fg.disable();
    } catch (std::exception &e) {
      BOOST_LOG(warning) << "Web UI Login failed: ["sv << net::addr_to_normalized_string(request->remote_endpoint().address())
                               << "]: "sv << e.what();
      response->write(SimpleWeb::StatusCode::server_error_internal_server_error);
      fg.disable();
      return;
    }
  }

  /**
   * @brief Start the HTTPS server.
   */
  void start() {
    auto shutdown_event = mail::man->event<bool>(mail::shutdown);
    auto port_https = net::map_port(PORT_HTTPS);
    auto address_family = net::af_from_enum_string(config::runtime.address_family);
    https_server_t server { config::shadow_http.cert, config::shadow_http.pkey };
    server.default_resource["DELETE"] = [](resp_https_t response, req_https_t request) {
      bad_request(response, request);
    };
    server.default_resource["PATCH"] = [](resp_https_t response, req_https_t request) {
      bad_request(response, request);
    };
    server.default_resource["POST"] = [](resp_https_t response, req_https_t request) {
      bad_request(response, request);
    };
    server.default_resource["PUT"] = [](resp_https_t response, req_https_t request) {
      bad_request(response, request);
    };
    server.default_resource["GET"] = not_found;
    server.resource["^/$"]["GET"] = getIndexPage;
    server.resource["^/pairing/?$"]["GET"] = getPairingPage;
    server.resource["^/clients/?$"]["GET"] = getClientsPage;
    server.resource["^/apps/?$"]["GET"] = getAppsPage;
    server.resource["^/config/?$"]["GET"] = getConfigPage;
    server.resource["^/password/?$"]["GET"] = getPasswordPage;
    server.resource["^/welcome/?$"]["GET"] = getWelcomePage;
    server.resource["^/login/?$"]["GET"] = getLoginPage;
    server.resource["^/troubleshooting/?$"]["GET"] = getTroubleshootingPage;
    server.resource["^/api/login"]["POST"] = login;
    server.resource["^/api/pairing/start$"]["POST"] = startShadowPairing;
    server.resource["^/api/pairing/status$"]["GET"] = getShadowPairingStatus;
    server.resource["^/api/pairing/requests$"]["GET"] = listShadowPairingRequests;
    server.resource["^/api/pairing/approve$"]["POST"] = approveShadowPairing;
    server.resource["^/api/pairing/reject$"]["POST"] = rejectShadowPairing;
    server.resource["^/api/apps$"]["GET"] = getApps;
    server.resource["^/api/apps$"]["POST"] = saveApp;
    server.resource["^/api/apps/reorder$"]["POST"] = reorderApps;
    server.resource["^/api/apps/delete$"]["POST"] = deleteApp;
    server.resource["^/api/apps/launch$"]["POST"] = launchApp;
    server.resource["^/api/apps/close$"]["POST"] = closeApp;
    server.resource["^/api/logs$"]["GET"] = getLogs;
    server.resource["^/api/config$"]["GET"] = getConfig;
    server.resource["^/api/config$"]["POST"] = saveConfig;
    server.resource["^/api/configLocale$"]["GET"] = getLocale;
    server.resource["^/api/restart$"]["POST"] = restart;
    server.resource["^/api/quit$"]["POST"] = quit;
    server.resource["^/api/reset-display-device-persistence$"]["POST"] = resetDisplayDevicePersistence;
    server.resource["^/api/password$"]["POST"] = savePassword;
    server.resource["^/api/clients/unpair-all$"]["POST"] = unpairAll;
    server.resource["^/api/clients/list$"]["GET"] = getClients;
    server.resource["^/api/clients/update$"]["POST"] = updateClient;
    server.resource["^/api/clients/unpair$"]["POST"] = unpair;
    server.resource["^/api/clients/disconnect$"]["POST"] = disconnect;
    server.resource["^/api/covers/upload$"]["POST"] = uploadCover;
    server.resource["^/images/lumen.ico$"]["GET"] = getFaviconImage;
    server.resource["^/images/logo-lumen-45.png$"]["GET"] = getLumenLogoImage;
    server.resource["^/assets\\/.+$"]["GET"] = getNodeModules;
    server.config.reuse_address = true;
    server.config.address = net::af_to_any_address_string(address_family);
    server.config.port = port_https;

    auto accept_and_run = [&](auto *server) {
      try {
        server->start([port_https](unsigned short port) {
          BOOST_LOG(info) << "Configuration UI available at [https://localhost:"sv << port << "]";
#ifdef __APPLE__
          platf::post_runtime_web_ui_ready_notification("https://localhost:" + std::to_string(port));
#endif
        });
      } catch (boost::system::system_error &err) {
        // It's possible the exception gets thrown after calling server->stop() from a different thread
        if (shutdown_event->peek())
          return;
        BOOST_LOG(fatal) << "Couldn't start Configuration HTTPS server on port ["sv << port_https << "]: "sv << err.what();
        shutdown_event->raise(true);
        return;
      }
    };
    std::thread tcp { accept_and_run, &server };

    // Wait for any event
    shutdown_event->view();

    server.stop();

    tcp.join();
  }
}  // namespace shadow_control_http
