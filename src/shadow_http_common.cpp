/**
 * @file src/shadow_http_common.cpp
 * @brief Definitions for shared Shadow HTTP helpers.
 */
#define BOOST_BIND_GLOBAL_PLACEHOLDERS

// standard includes
#include <algorithm>
#include <filesystem>
#include <fstream>
#include <set>
#include <utility>

// lib includes
#include <boost/algorithm/string.hpp>
#include <boost/asio/ssl/context.hpp>
#include <boost/asio/ssl/context_base.hpp>
#include <boost/property_tree/json_parser.hpp>
#include <boost/property_tree/ptree.hpp>
#include <boost/property_tree/xml_parser.hpp>
#include <curl/curl.h>
#include <Simple-Web-Server/server_http.hpp>
#include <Simple-Web-Server/server_https.hpp>

// local includes
#include "config.h"
#include "crypto.h"
#include "file_handler.h"
#include "shadow_http_common.h"
#include "logging.h"
#include "network.h"
#include "shadow_http.h"
#include "platform/common.h"
#include "process.h"
#include "rtsp.h"
#include "utility.h"

namespace shadow_http_common {
  using namespace std::literals;
  namespace fs = std::filesystem;
  namespace pt = boost::property_tree;

  int reload_user_creds(const std::string &file);
  bool user_creds_exist(const std::string &file);

  std::string unique_id;
  uuid_util::uuid_t uuid;
  net::net_e origin_admin_allowed;
  std::string discovery_authority_host;

  namespace {
    std::string normalized_discovery_authority_host(std::string host) {
      boost::trim(host);
      if (host.empty()) {
        return {};
      }

      if (host.front() == '[') {
        const auto end = host.find(']');
        if (end == std::string::npos) {
          return {};
        }
        host = host.substr(1, end - 1);
      } else {
        const auto colon_count = std::count(host.begin(), host.end(), ':');
        if (colon_count == 1) {
          const auto port_delimiter = host.rfind(':');
          if (port_delimiter != std::string::npos) {
            host.resize(port_delimiter);
          }
        }
      }

      boost::trim(host);
      while (!host.empty() && host.back() == '.') {
        host.pop_back();
      }
      if (host.empty()) {
        return {};
      }

      const auto local_host_name = platf::get_host_name();
      const std::set<std::string> rejected_hosts {
        local_host_name,
        local_host_name + ".local",
        net::mdns_instance_name(local_host_name),
        net::mdns_instance_name(local_host_name) + ".local",
        "localhost"
      };

      if (rejected_hosts.contains(host)) {
        return {};
      }

      const auto net_type = net::from_address(host);
      if (net_type == net::PC || net_type == net::LAN) {
        return {};
      }

      return host;
    }

    void persist_discovery_authority_state() {
      nlohmann::json root = nlohmann::json::object();
      if (fs::exists(config::shadow_http.file_state)) {
        try {
          std::ifstream in(config::shadow_http.file_state);
          in >> root;
        } catch (const std::exception &e) {
          BOOST_LOG(error) << "Couldn't read "sv << config::shadow_http.file_state << " while persisting authority host: "sv << e.what();
          return;
        }
      }

      auto &root_node = root["root"];
      if (!root_node.is_object()) {
        root_node = nlohmann::json::object();
      }

      if (discovery_authority_host.empty()) {
        root_node.erase("authority_host");
      } else {
        root_node["authority_host"] = discovery_authority_host;
      }

      try {
        std::ofstream out(config::shadow_http.file_state);
        out << root.dump(4);
      } catch (const std::exception &e) {
        BOOST_LOG(error) << "Couldn't write "sv << config::shadow_http.file_state << " while persisting authority host: "sv << e.what();
      }
    }
  }  // namespace

  int init() {
    bool clean_slate = config::runtime.flags[config::flag::FRESH_STATE];
    origin_admin_allowed = net::from_enum_string(config::shadow_http.origin_admin_allowed);
    load_discovery_authority_state();

    if (clean_slate) {
      uuid = uuid_util::uuid_t::generate();
      unique_id = uuid.string();
      auto dir = std::filesystem::temp_directory_path() / "Lumen"sv;
      config::shadow_http.cert = (dir / ("cert-"s + unique_id)).string();
      config::shadow_http.pkey = (dir / ("pkey-"s + unique_id)).string();
    }

    if ((!fs::exists(config::shadow_http.pkey) || !fs::exists(config::shadow_http.cert)) &&
        create_creds(config::shadow_http.pkey, config::shadow_http.cert)) {
      return -1;
    }
    if (!user_creds_exist(config::runtime.credentials_file)) {
      BOOST_LOG(info) << "Open the Web UI to set your new username and password and getting started";
    } else if (reload_user_creds(config::runtime.credentials_file)) {
      return -1;
    }
    return 0;
  }

  void load_discovery_authority_state() {
    discovery_authority_host.clear();

    if (!fs::exists(config::shadow_http.file_state)) {
      return;
    }

    try {
      nlohmann::json root;
      std::ifstream in(config::shadow_http.file_state);
      in >> root;

      if (root.contains("root") && root["root"].is_object()) {
        const auto authority_host = normalized_discovery_authority_host(root["root"].value("authority_host", ""s));
        if (!authority_host.empty()) {
          discovery_authority_host = authority_host;
        }
      }
    } catch (const std::exception &e) {
      BOOST_LOG(error) << "Couldn't read "sv << config::shadow_http.file_state << " while loading authority host: "sv << e.what();
    }
  }

  bool observe_discovery_authority_host(const std::string_view &host) {
    auto normalized_host = normalized_discovery_authority_host(std::string {host});
    if (normalized_host.empty() || normalized_host == discovery_authority_host) {
      return false;
    }

    discovery_authority_host = std::move(normalized_host);
    persist_discovery_authority_state();
    BOOST_LOG(info) << "Observed discovery authority host "sv << discovery_authority_host;
    return true;
  }

  int save_user_creds(const std::string &file, const std::string &username, const std::string &password, bool run_our_mouth) {
    nlohmann::json outputTree;

    if (fs::exists(file)) {
      try {
        std::ifstream in(file);
        in >> outputTree;
      } catch (std::exception &e) {
        BOOST_LOG(error) << "Couldn't read user credentials: "sv << e.what();
        return -1;
      }
    }

    auto salt = crypto::rand_alphabet(16);
    outputTree["username"] = username;
    outputTree["salt"] = salt;
    outputTree["password"] = util::hex(crypto::hash(password + salt)).to_string();
    try {
      std::ofstream out(file);
      out << outputTree.dump(4);  // Pretty-print with an indent of 4 spaces.
    } catch (std::exception &e) {
      BOOST_LOG(error) << "error writing to the credentials file, perhaps try this again as an administrator? Details: "sv << e.what();
      return -1;
    }

    BOOST_LOG(info) << "New credentials have been created"sv;
    return 0;
  }

  bool user_creds_exist(const std::string &file) {
    if (!fs::exists(file)) {
      return false;
    }

    pt::ptree inputTree;
    try {
      pt::read_json(file, inputTree);
      return inputTree.find("username") != inputTree.not_found() &&
             inputTree.find("password") != inputTree.not_found() &&
             inputTree.find("salt") != inputTree.not_found();
    } catch (std::exception &e) {
      BOOST_LOG(error) << "validating user credentials: "sv << e.what();
    }

    return false;
  }

  int reload_user_creds(const std::string &file) {
    pt::ptree inputTree;
    try {
      pt::read_json(file, inputTree);
      config::runtime.username = inputTree.get<std::string>("username");
      config::runtime.password = inputTree.get<std::string>("password");
      config::runtime.salt = inputTree.get<std::string>("salt");
    } catch (std::exception &e) {
      BOOST_LOG(error) << "loading user credentials: "sv << e.what();
      return -1;
    }
    return 0;
  }

  int create_creds(const std::string &pkey, const std::string &cert) {
    fs::path pkey_path = pkey;
    fs::path cert_path = cert;

    auto creds = crypto::gen_creds("Lumen Gamestream Host"sv, 2048);

    auto pkey_dir = pkey_path;
    auto cert_dir = cert_path;
    pkey_dir.remove_filename();
    cert_dir.remove_filename();

    std::error_code err_code {};
    fs::create_directories(pkey_dir, err_code);
    if (err_code) {
      BOOST_LOG(error) << "Couldn't create directory ["sv << pkey_dir << "] :"sv << err_code.message();
      return -1;
    }

    fs::create_directories(cert_dir, err_code);
    if (err_code) {
      BOOST_LOG(error) << "Couldn't create directory ["sv << cert_dir << "] :"sv << err_code.message();
      return -1;
    }

    if (file_handler::write_file(pkey.c_str(), creds.pkey)) {
      BOOST_LOG(error) << "Couldn't open ["sv << config::shadow_http.pkey << ']';
      return -1;
    }

    if (file_handler::write_file(cert.c_str(), creds.x509)) {
      BOOST_LOG(error) << "Couldn't open ["sv << config::shadow_http.cert << ']';
      return -1;
    }

    fs::permissions(pkey_path, fs::perms::owner_read | fs::perms::owner_write, fs::perm_options::replace, err_code);

    if (err_code) {
      BOOST_LOG(error) << "Couldn't change permissions of ["sv << config::shadow_http.pkey << "] :"sv << err_code.message();
      return -1;
    }

    fs::permissions(cert_path, fs::perms::owner_read | fs::perms::group_read | fs::perms::others_read | fs::perms::owner_write, fs::perm_options::replace, err_code);

    if (err_code) {
      BOOST_LOG(error) << "Couldn't change permissions of ["sv << config::shadow_http.cert << "] :"sv << err_code.message();
      return -1;
    }

    return 0;
  }

  bool download_file(const std::string &url, const std::string &file, long ssl_version) {
    // sonar complains about weak ssl and tls versions; however sonar cannot detect the fix
    CURL *curl = curl_easy_init();  // NOSONAR
    if (!curl) {
      BOOST_LOG(error) << "Couldn't create CURL instance";
      return false;
    }

    if (std::string file_dir = file_handler::get_parent_directory(file); !file_handler::make_directory(file_dir)) {
      BOOST_LOG(error) << "Couldn't create directory ["sv << file_dir << ']';
      curl_easy_cleanup(curl);
      return false;
    }

    FILE *fp = fopen(file.c_str(), "wb");
    if (!fp) {
      BOOST_LOG(error) << "Couldn't open ["sv << file << ']';
      curl_easy_cleanup(curl);
      return false;
    }

    curl_easy_setopt(curl, CURLOPT_SSLVERSION, ssl_version);  // NOSONAR
    curl_easy_setopt(curl, CURLOPT_URL, url.c_str());
    curl_easy_setopt(curl, CURLOPT_WRITEFUNCTION, fwrite);
    curl_easy_setopt(curl, CURLOPT_WRITEDATA, fp);
    curl_easy_setopt(curl, CURLOPT_SSLVERSION, CURL_SSLVERSION_TLSv1_2);
#ifdef _WIN32
    curl_easy_setopt(curl, CURLOPT_SSL_OPTIONS, CURLSSLOPT_NATIVE_CA);
#endif
    CURLcode result = curl_easy_perform(curl);
    if (result != CURLE_OK) {
      BOOST_LOG(error) << "Couldn't download ["sv << url << ", code:" << result << ']';
    }
    curl_easy_cleanup(curl);
    fclose(fp);
    return result == CURLE_OK;
  }

  std::string url_escape(const std::string &url) {
    char *string = curl_easy_escape(nullptr, url.c_str(), static_cast<int>(url.length()));
    std::string result(string);
    curl_free(string);
    return result;
  }

  std::string url_get_host(const std::string &url) {
    CURLU *curlu = curl_url();
    curl_url_set(curlu, CURLUPART_URL, url.c_str(), static_cast<unsigned int>(url.length()));
    char *host;
    if (curl_url_get(curlu, CURLUPART_HOST, &host, 0) != CURLUE_OK) {
      curl_url_cleanup(curlu);
      return "";
    }
    std::string result(host);
    curl_free(host);
    curl_url_cleanup(curlu);
    return result;
  }
}  // namespace shadow_http_common
