/**
 * @file src/shadow_control_http.h
 * @brief Declarations for the Shadow control Web UI HTTPS server.
 */
#pragma once

// standard includes
#include <cstdint>
#include <functional>
#include <chrono>
#include <string>

// local includes
#include "thread_safe.h"

#define WEB_DIR SUNSHINE_ASSETS_DIR "/web/"

using namespace std::chrono_literals;

namespace shadow_control_http {
  constexpr auto PORT_HTTPS = 1;
  constexpr auto SESSION_EXPIRE_DURATION = 24h * 15;

  struct shadow_pairing_request_snapshot_t {
    std::string pairing_id;
    std::string user_code;
    std::string device_name;
    std::string platform;
    std::string client_id;
    std::string trusted_client_uuid;
    bool public_key_present = false;
    bool client_trusted = false;
    bool client_certificate_required = true;
    std::string status;
    std::string server_unique_id;
    std::string service_type;
    std::uint16_t control_https_port = 0;
    std::int64_t expires_in_seconds = 0;
    std::int64_t poll_interval_seconds = 0;
  };

  shadow_pairing_request_snapshot_t create_pairing_request(
    std::string device_name,
    std::string platform,
    std::string client_id,
    std::string public_key
  );

  void start();
}  // namespace shadow_control_http

// mime types map
const std::map<std::string, std::string> mime_types = {
  {"css", "text/css"},
  {"gif", "image/gif"},
  {"htm", "text/html"},
  {"html", "text/html"},
  {"ico", "image/x-icon"},
  {"jpeg", "image/jpeg"},
  {"jpg", "image/jpeg"},
  {"js", "application/javascript"},
  {"json", "application/json"},
  {"png", "image/png"},
  {"svg", "image/svg+xml"},
  {"ttf", "font/ttf"},
  {"txt", "text/plain"},
  {"woff2", "font/woff2"},
  {"xml", "text/xml"},
};
