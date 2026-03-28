/**
 * @file src/stream.cpp
 * @brief Definitions for the streaming protocols.
 */

// standard includes
#include <cstdlib>
#include <fstream>
#include <future>
#include <queue>

// lib includes
#include <boost/endian/arithmetic.hpp>
#include <openssl/err.h>

extern "C" {
  // clang-format off
#include <moonlight-common-c/src/Limelight-internal.h>
#include "rswrapper.h"
#ifdef __APPLE__
#include "ApolloCore.h"
#endif
  // clang-format on
}

// local includes
#include "config.h"
#include "crypto.h"
#include "display_device.h"
#include "globals.h"
#include "input.h"
#include "logging.h"
#include "network.h"
#include "platform/common.h"
#ifdef __APPLE__
#include "platform/macos/misc.h"
#endif
#include "process.h"
#include "stream.h"
#include "sync.h"
#include "system_tray.h"
#include "thread_safe.h"
#include "utility.h"

#define IDX_START_A 0
#define IDX_START_B 1
#define IDX_INVALIDATE_REF_FRAMES 2
#define IDX_LOSS_STATS 3
#define IDX_INPUT_DATA 5
#define IDX_RUMBLE_DATA 6
#define IDX_TERMINATION 7
#define IDX_PERIODIC_PING 8
#define IDX_REQUEST_IDR_FRAME 9
#define IDX_ENCRYPTED 10
#define IDX_RUMBLE_TRIGGER_DATA 12
#define IDX_SET_MOTION_EVENT 13
#define IDX_SET_RGB_LED 14
#define IDX_EXEC_SERVER_CMD 15
#define IDX_SET_CLIPBOARD 16
#define IDX_FILE_TRANSFER_NONCE_REQUEST 17
#define IDX_SET_ADAPTIVE_TRIGGERS 18
#define IDX_HDR_FRAME_STATE 19

static const short packetTypes[] = {
  0x0305,  // Start A
  0x0307,  // Start B
  0x0301,  // Invalidate reference frames
  0x0201,  // Loss Stats
  0x0204,  // Frame Stats (unused)
  0x0206,  // Input data
  0x010b,  // Rumble data
  0x0109,  // Termination
  0x0200,  // Periodic Ping
  0x0302,  // IDR frame
  0x0001,  // fully encrypted
  0x010e,  // retired HDR mode (reserved)
  0x5500,  // Rumble triggers (Sunshine protocol extension)
  0x5501,  // Set motion event (Sunshine protocol extension)
  0x5502,  // Set RGB LED (Sunshine protocol extension)
  0x3000,  // Execute Server Command (Apollo protocol extension)
  0x3001,  // Set Clipboard (Apollo protocol extension)
  0x3002,  // File transfer nonce request (Apollo protocol extension)
  0x5503,  // Set Adaptive triggers (Sunshine protocol extension)
  0x3003,  // HDR frame state v2 (Apollo protocol extension)
};

namespace asio = boost::asio;
namespace sys = boost::system;

using asio::ip::tcp;
using asio::ip::udp;

using namespace std::literals;

namespace stream {
  struct session_t;

  constexpr std::size_t max_video_send_batch_bytes = 64 * 1024;
  constexpr std::size_t max_video_send_batch_packets = 64;
  constexpr int high_refresh_low_latency_fps = 90;
  constexpr int ultra_high_refresh_low_latency_fps = 110;
  constexpr std::size_t high_refresh_send_batch_packets_cap = 12;
  constexpr std::size_t high_refresh_send_batch_divisor = 6;
  constexpr std::size_t ultra_high_refresh_send_batch_packets_cap = 8;
  constexpr std::size_t ultra_high_refresh_send_batch_divisor = 8;
  constexpr auto default_send_pacing_quantum = 1ms;
  constexpr auto high_refresh_send_pacing_quantum = 333us;
  constexpr auto ultra_high_refresh_send_pacing_quantum = 250us;
  constexpr std::size_t high_refresh_send_pacing_divisor = 3;
  constexpr std::size_t ultra_high_refresh_send_pacing_divisor = 4;
  constexpr std::uint8_t shadow_multi_fec_flags = 0x10;

  enum class socket_e : int {
    video,  ///< Video
    audio  ///< Audio
  };

#pragma pack(push, 1)

  struct video_short_frame_header_t {
    uint8_t *payload() {
      return (uint8_t *) (this + 1);
    }

    std::uint8_t headerType;  // Always 0x01 for short headers

    // Sunshine extension
    // Frame processing latency, in 1/10 ms units
    //     zero when the frame is repeated or there is no backend implementation
    boost::endian::little_uint16_at frame_processing_latency;

    // Currently known values:
    // 1 = Normal P-frame
    // 2 = IDR-frame
    // 4 = P-frame with intra-refresh blocks
    // 5 = P-frame after reference frame invalidation
    std::uint8_t frameType;

    // Length of the final packet payload for codecs that cannot handle
    // zero padding, such as AV1 (Sunshine extension).
    boost::endian::little_uint16_at lastPayloadLen;

    std::uint8_t unknown[2];
  };

  static_assert(
    sizeof(video_short_frame_header_t) == 8,
    "Short frame header must be 8 bytes"
  );

  struct video_packet_raw_t {
    uint8_t *payload() {
      return (uint8_t *) (this + 1);
    }

    RTP_PACKET rtp;
    char reserved[4];

    NV_VIDEO_PACKET packet;
  };

  struct video_packet_enc_prefix_t {
    std::uint8_t iv[12];  // 12-byte IV is ideal for AES-GCM
    std::uint32_t frameNumber;
    std::uint8_t tag[16];
  };

  struct audio_packet_t {
    RTP_PACKET rtp;
  };

  struct control_header_v2 {
    std::uint16_t type;
    std::uint16_t payloadLength;

    uint8_t *payload() {
      return (uint8_t *) (this + 1);
    }
  };

  struct control_terminate_t {
    control_header_v2 header;

    std::uint32_t ec;
  };

  struct control_rumble_t {
    control_header_v2 header;

    std::uint32_t useless;

    std::uint16_t id;
    std::uint16_t lowfreq;
    std::uint16_t highfreq;
  };

  struct control_rumble_triggers_t {
    control_header_v2 header;

    std::uint16_t id;
    std::uint16_t left;
    std::uint16_t right;
  };

  struct control_set_motion_event_t {
    control_header_v2 header;

    std::uint16_t id;
    std::uint16_t reportrate;
    std::uint8_t type;
  };

  struct control_set_rgb_led_t {
    control_header_v2 header;

    std::uint16_t id;
    std::uint8_t r;
    std::uint8_t g;
    std::uint8_t b;
  };

  struct control_adaptive_triggers_t {
    control_header_v2 header;

    std::uint16_t id;
    /**
     * 0x04 - Right trigger
     * 0x08 - Left trigger
     */
    std::uint8_t event_flags;
    std::uint8_t type_left;
    std::uint8_t type_right;
    std::uint8_t left[DS_EFFECT_PAYLOAD_SIZE];
    std::uint8_t right[DS_EFFECT_PAYLOAD_SIZE];
  };

  struct control_hdr_frame_state_v2_t {
    control_header_v2 header;

    std::uint8_t version;
    std::uint8_t frameDynamicRange;
    std::uint8_t flags;
    std::uint8_t reserved;
    boost::endian::little_uint32_at effectiveFromFrameNumber;
    boost::endian::little_uint16_at overlayRegionCount;
    std::uint16_t reserved2;
    SS_HDR_METADATA staticMetadata;
  };

  struct control_hdr_overlay_region_v2_t {
    boost::endian::little_uint16_at x;
    boost::endian::little_uint16_at y;
    boost::endian::little_uint16_at width;
    boost::endian::little_uint16_at height;
    std::uint8_t flags;
    std::uint8_t reserved[3];
    SS_HDR_METADATA metadata;
  };

  typedef struct control_encrypted_t {
    std::uint16_t encryptedHeaderType;  // Always LE 0x0001
    std::uint16_t length;  // sizeof(seq) + 16 byte tag + secondary header and data

    // seq is carried through as the per-packet AES-GCM IV counter input.
    std::uint32_t seq;  // Monotonically increasing sequence number (used as IV for AES-GCM)

    uint8_t *payload() {
      return (uint8_t *) (this + 1);
    }

    // encrypted control_header_v2 and payload data follow
  } *control_encrypted_p;

  struct audio_fec_packet_t {
    RTP_PACKET rtp;
    AUDIO_FEC_HEADER fecHeader;
  };

#pragma pack(pop)

  constexpr std::size_t round_to_pkcs7_padded(std::size_t size) {
    return ((size + 15) / 16) * 16;
  }

  constexpr std::size_t MAX_AUDIO_PACKET_SIZE = 1400;

  using audio_aes_t = std::array<char, round_to_pkcs7_padded(MAX_AUDIO_PACKET_SIZE)>;

  using av_session_id_t = std::variant<asio::ip::address, std::string>;  // IP address or SS-Ping-Payload from RTSP handshake
  using message_queue_t = std::shared_ptr<safe::queue_t<std::pair<udp::endpoint, std::string>>>;
  struct message_queue_registration_t {
    socket_e socket_type;
    av_session_id_t session_id;
    message_queue_t message_queue;
    session_t *session;
  };
  using message_queue_queue_t = std::shared_ptr<safe::queue_t<message_queue_registration_t>>;

  // return bytes written on success
  // return -1 on error
  static inline int encode_audio(bool encrypted, const audio::buffer_t &plaintext, uint8_t *destination, crypto::aes_t &iv, crypto::cipher::cbc_t &cbc) {
    // If encryption isn't enabled
    if (!encrypted) {
      std::copy(std::begin(plaintext), std::end(plaintext), destination);
      return plaintext.size();
    }

    return cbc.encrypt(std::string_view {(char *) std::begin(plaintext), plaintext.size()}, destination, &iv);
  }

  static inline void while_starting_do_nothing(std::atomic<session::state_e> &state) {
    while (state.load(std::memory_order_acquire) == session::state_e::STARTING) {
      std::this_thread::sleep_for(1ms);
    }
  }

  class control_server_t {
  public:
    int bind(net::af_e address_family, std::uint16_t port) {
      _host = net::host_create(address_family, _addr, port);

      return !(bool) _host;
    }

    // Get session associated with address.
    // If none are found, try to find a session not yet claimed. (It will be marked by a port of value 0
    // If none of those are found, return nullptr
    session_t *get_session(const net::peer_t peer, uint32_t connect_data);

    // Circular dependency:
    //   iterate refers to session
    //   session refers to broadcast_ctx_t
    //   broadcast_ctx_t refers to control_server_t
    // Therefore, iterate is implemented further down the source file
    void iterate(std::chrono::milliseconds timeout);

    /**
     * @brief Call the handler for a given control stream message.
     * @param type The message type.
     * @param session The session the message was received on.
     * @param payload The payload of the message.
     * @param reinjected `true` if this message is being reprocessed after decryption.
     */
    void call(std::uint16_t type, session_t *session, const std::string_view &payload, bool reinjected);

    void map(uint16_t type, std::function<void(session_t *, const std::string_view &)> cb) {
      _map_type_cb.emplace(type, std::move(cb));
    }

    int send(const std::string_view &payload, net::peer_t peer) {
      auto packet = enet_packet_create(payload.data(), payload.size(), ENET_PACKET_FLAG_RELIABLE);
      if (enet_peer_send(peer, 0, packet)) {
        enet_packet_destroy(packet);

        return -1;
      }

      return 0;
    }

    void flush() {
      enet_host_flush(_host.get());
    }

    // Callbacks
    std::unordered_map<std::uint16_t, std::function<void(session_t *, const std::string_view &)>> _map_type_cb;

    // All active sessions (including those still waiting for a peer to connect)
    sync_util::sync_t<std::vector<session_t *>> _sessions;

    // ENet peer to session mapping for sessions with a peer connected
    sync_util::sync_t<std::map<net::peer_t, session_t *>> _peer_to_session;

    ENetAddress _addr;
    net::host_t _host;
  };

  struct broadcast_ctx_t {
    message_queue_queue_t message_queue_queue;

    std::thread recv_thread;
    std::thread video_thread;
    std::thread audio_thread;
    std::thread control_thread;

    asio::io_context io_context;

    udp::socket video_sock {io_context};
    udp::socket audio_sock {io_context};

    control_server_t control_server;
  };

  struct session_t {
    config_t config;

    safe::mail_t mail;

    std::shared_ptr<input::input_t> input;

    std::thread audioThread;
    std::thread videoThread;

    std::chrono::steady_clock::time_point pingTimeout;

    safe::shared_t<broadcast_ctx_t>::ptr_t broadcast_ref;

    boost::asio::ip::address localAddress;

    struct {
      std::string ping_payload;

      int lowseq;
      udp::endpoint peer;

      std::optional<crypto::cipher::gcm_t> cipher;
      std::uint64_t gcm_iv_counter;

      safe::mail_raw_t::event_t<bool> idr_events;
      safe::mail_raw_t::event_t<std::pair<int64_t, int64_t>> invalidate_ref_frames_events;

      std::unique_ptr<platf::deinit_t> qos;
    } video;

    struct {
      crypto::cipher::cbc_t cipher;
      std::string ping_payload;

      std::uint16_t sequenceNumber;
      // avRiKeyId == util::endian::big(First (sizeof(avRiKeyId)) bytes of launch_session->iv)
      std::uint32_t avRiKeyId;
      std::uint32_t timestamp;
      udp::endpoint peer;

      util::buffer_t<char> shards;
      util::buffer_t<uint8_t *> shards_p;

      audio_fec_packet_t fec_packet;
      std::unique_ptr<platf::deinit_t> qos;
    } audio;

    struct {
      crypto::cipher::gcm_t cipher;
      crypto::aes_t incoming_iv;
      crypto::aes_t outgoing_iv;

      std::uint32_t connect_data;  // Required for Shadow session identifier matching
      std::string expected_peer_address;

      net::peer_t peer;
      std::uint32_t seq;

      platf::feedback_queue_t feedback_queue;
      std::optional<video::hdr_frame_state_t> last_sent_hdr_frame_state;
    } control;

    std::uint32_t launch_session_id;
    std::string device_name;
    std::string device_uuid;
    crypto::PERM permission;

    std::list<crypto::command_entry_t> do_cmds;
    std::list<crypto::command_entry_t> undo_cmds;

    safe::mail_raw_t::event_t<bool> shutdown_event;
    safe::signal_t controlEnd;

    std::atomic<session::state_e> state;
  };

  static std::optional<boost::asio::ip::address> resolve_local_source_address(session_t &session, const std::string_view &control_local_address) {
    if (auto address = net::parse_address(control_local_address)) {
      return address;
    }

    if (!session.localAddress.is_unspecified()) {
      return session.localAddress;
    }

    auto peer_address = session.video.peer.address();
    if (peer_address.is_unspecified()) {
      return std::nullopt;
    }

    return net::local_address_for_target(peer_address);
  }

  /**
   * First part of cipher must be struct of type control_encrypted_t
   *
   * returns empty string_view on failure
   * returns string_view pointing to payload data
   */
  template<std::size_t max_payload_size>
  static inline std::string_view encode_control(session_t *session, const std::string_view &plaintext, std::array<std::uint8_t, max_payload_size> &tagged_cipher) {
    static_assert(
      max_payload_size >= sizeof(control_encrypted_t) + sizeof(crypto::cipher::tag_size),
      "max_payload_size >= sizeof(control_encrypted_t) + sizeof(crypto::cipher::tag_size)"
    );

    if (session->config.controlProtocolType != 13) {
      return plaintext;
    }

    auto seq = session->control.seq++;

    auto &iv = session->control.outgoing_iv;
    // We use the deterministic IV construction algorithm specified in NIST SP 800-38D
    // Section 8.2.1. The sequence number is our "invocation" field and the 'CH' in the
    // high bytes is the "fixed" field. Because each client provides their own unique
    // key, our values in the fixed field need only uniquely identify each independent
    // use of the client's key with AES-GCM in our code.
    //
    // The sequence number is 32 bits long which allows for 2^32 control stream messages
    // to be sent to each client before the IV repeats.
    iv.resize(12);
    std::copy_n((uint8_t *) &seq, sizeof(seq), std::begin(iv));
    iv[10] = 'H';  // Host originated
    iv[11] = 'C';  // Control stream

    auto packet = (control_encrypted_p) tagged_cipher.data();

    auto bytes = session->control.cipher.encrypt(plaintext, packet->payload(), &iv);
    if (bytes <= 0) {
      BOOST_LOG(error) << "Couldn't encrypt control data"sv;
      return {};
    }

    std::uint16_t packet_length = bytes + crypto::cipher::tag_size + sizeof(control_encrypted_t::seq);

    packet->encryptedHeaderType = util::endian::little(0x0001);
    packet->length = util::endian::little(packet_length);
    packet->seq = util::endian::little(seq);

    return std::string_view {(char *) tagged_cipher.data(), packet_length + sizeof(control_encrypted_t) - sizeof(control_encrypted_t::seq)};
  }

  static inline std::string_view encode_control_dynamic(
    session_t *session,
    const std::string_view &plaintext,
    std::vector<std::uint8_t> &tagged_cipher
  ) {
    if (session->config.controlProtocolType != 13) {
      return plaintext;
    }

    auto seq = session->control.seq++;

    auto &iv = session->control.outgoing_iv;
    iv.resize(12);
    std::copy_n((uint8_t *) &seq, sizeof(seq), std::begin(iv));
    iv[10] = 'H';
    iv[11] = 'C';

    auto *packet = reinterpret_cast<control_encrypted_p>(tagged_cipher.data());
    auto bytes = session->control.cipher.encrypt(plaintext, packet->payload(), &iv);
    if (bytes <= 0) {
      BOOST_LOG(error) << "Couldn't encrypt control data"sv;
      return {};
    }

    std::uint16_t packet_length = bytes + crypto::cipher::tag_size + sizeof(control_encrypted_t::seq);
    packet->encryptedHeaderType = util::endian::little(0x0001);
    packet->length = util::endian::little(packet_length);
    packet->seq = util::endian::little(seq);

    return std::string_view {
      reinterpret_cast<char *>(tagged_cipher.data()),
      packet_length + sizeof(control_encrypted_t) - sizeof(control_encrypted_t::seq)
    };
  }

  int start_broadcast(broadcast_ctx_t &ctx);
  void end_broadcast(broadcast_ctx_t &ctx);

  static auto broadcast = safe::make_shared<broadcast_ctx_t>(start_broadcast, end_broadcast);

  session_t *control_server_t::get_session(const net::peer_t peer, uint32_t connect_data) {
    {
      // Fast path - look up existing session by peer
      auto lg = _peer_to_session.lock();
      auto it = _peer_to_session->find(peer);
      if (it != _peer_to_session->end()) {
        return it->second;
      }
    }

    // Slow path - process new session
    TUPLE_2D(peer_port, peer_addr, platf::from_sockaddr_ex((sockaddr *) &peer->address.address));
    auto lg = _sessions.lock();
    for (auto pos = std::begin(*_sessions); pos != std::end(*_sessions); ++pos) {
      auto session_p = *pos;

      // Skip sessions that are already established
      if (session_p->control.peer) {
        continue;
      }

      if (session_p->control.connect_data != connect_data) {
        continue;
      } else {
        BOOST_LOG(debug) << "Initialized new control stream session by Shadow session identifier"sv;
      }

      // Use the local address from the control connection as the source address
      // for other communications to the client. This is necessary to ensure
      // proper routing on multi-homed hosts.
      auto local_address = platf::from_sockaddr((sockaddr *) &peer->localAddress.address);
      auto resolved_local_address = resolve_local_source_address(*session_p, local_address);
      if (!resolved_local_address) {
        BOOST_LOG(warning) << "Rejecting control connection from ["sv << peer_addr << ':' << peer_port
                           << "]: unable to determine a local source address"sv;
        continue;
      }

      // Once the control stream connection is established, RTSP session state can be torn down
      rtsp_stream::launch_session_clear(session_p->launch_session_id);

      session_p->control.peer = peer;
      session_p->localAddress = *resolved_local_address;

      if (net::parse_address(local_address)) {
        BOOST_LOG(debug) << "Control local address ["sv << local_address << ']';
      } else {
        auto logged_local_address = local_address.empty() ? std::string {"<unavailable>"} : local_address;
        BOOST_LOG(warning) << "Control local address ["sv << logged_local_address
                           << "] is invalid; using ["sv << net::addr_to_normalized_string(session_p->localAddress) << "] instead"sv;
      }
      BOOST_LOG(debug) << "Control peer address ["sv << peer_addr << ':' << peer_port << ']';

      // Insert this into the map for O(1) lookups in the future
      auto ptslg = _peer_to_session.lock();
      _peer_to_session->emplace(peer, session_p);
      return session_p;
    }

    return nullptr;
  }

  /**
   * @brief Call the handler for a given control stream message.
   * @param type The message type.
   * @param session The session the message was received on.
   * @param payload The payload of the message.
   * @param reinjected `true` if this message is being reprocessed after decryption.
   */
  void control_server_t::call(std::uint16_t type, session_t *session, const std::string_view &payload, bool reinjected) {
    // If we are using the encrypted control stream protocol, drop any messages that come off the wire unencrypted
    if (session->config.controlProtocolType == 13 && !reinjected && type != packetTypes[IDX_ENCRYPTED]) {
      BOOST_LOG(error) << "Dropping unencrypted message on encrypted control stream: "sv << util::hex(type).to_string_view();
      return;
    }

    auto cb = _map_type_cb.find(type);
    if (cb == std::end(_map_type_cb)) {
      BOOST_LOG(debug)
        << "type [Unknown] { "sv << util::hex(type).to_string_view() << " }"sv << std::endl
        << "---data---"sv << std::endl
        << util::hex_vec(payload) << std::endl
        << "---end data---"sv;
    } else {
      cb->second(session, payload);
    }
  }

  void control_server_t::iterate(std::chrono::milliseconds timeout) {
    ENetEvent event;
    auto res = enet_host_service(_host.get(), &event, timeout.count());

    if (res > 0) {
      auto session = get_session(event.peer, event.data);
      if (!session) {
        BOOST_LOG(warning) << "Rejected connection from ["sv << platf::from_sockaddr((sockaddr *) &event.peer->address.address) << "]: it's not properly set up"sv;
        enet_peer_disconnect_now(event.peer, 0);

        return;
      }

      session->pingTimeout = std::chrono::steady_clock::now() + config::stream.ping_timeout;

      switch (event.type) {
        case ENET_EVENT_TYPE_RECEIVE:
          {
            net::packet_t packet {event.packet};

            auto type = *(std::uint16_t *) packet->data;
            std::string_view payload {(char *) packet->data + sizeof(type), packet->dataLength - sizeof(type)};

            call(type, session, payload, false);
          }
          break;
        case ENET_EVENT_TYPE_CONNECT:
          BOOST_LOG(info) << "CLIENT CONNECTED"sv;
          proc::proc.on_stream_connected();
          break;
        case ENET_EVENT_TYPE_DISCONNECT:
          BOOST_LOG(info) << "CLIENT DISCONNECTED"sv;
          proc::proc.on_stream_disconnected();
          // No more clients to send video data to ^_^
          if (session->state == session::state_e::RUNNING) {
            session::stop(*session);
          }
          break;
        case ENET_EVENT_TYPE_NONE:
          break;
      }
    }
  }

  namespace fec {
    using rs_t = util::safe_ptr<reed_solomon, [](reed_solomon *rs) {
      reed_solomon_release(rs);
    }>;

    struct fec_t {
      size_t data_shards;
      size_t nr_shards;
      size_t percentage;

      size_t blocksize;
      size_t prefixsize;
      util::buffer_t<char> shards;
      util::buffer_t<char> headers;
      util::buffer_t<uint8_t *> shards_p;

      std::vector<platf::buffer_descriptor_t> payload_buffers;

      char *data(size_t el) {
        return (char *) shards_p[el];
      }

      char *prefix(size_t el) {
        return prefixsize ? &headers[el * prefixsize] : nullptr;
      }

      size_t size() const {
        return nr_shards;
      }
    };

    static fec_t encode(const std::string_view &payload, size_t blocksize, size_t fecpercentage, size_t minparityshards, size_t prefixsize) {
      auto payload_size = payload.size();

      auto pad = payload_size % blocksize != 0;

      auto aligned_data_shards = payload_size / blocksize;
      auto data_shards = aligned_data_shards + (pad ? 1 : 0);
      auto parity_shards = (data_shards * fecpercentage + 99) / 100;

      // increase the FEC percentage for this frame if the parity shard minimum is not met
      if (parity_shards < minparityshards && fecpercentage != 0) {
        parity_shards = minparityshards;
        fecpercentage = (100 * parity_shards) / data_shards;

        BOOST_LOG(verbose) << "Increasing FEC percentage to "sv << fecpercentage << " to meet parity shard minimum"sv << std::endl;
      }

      auto nr_shards = data_shards + parity_shards;

      // If we need to store a zero-padded data shard, allocate that first to
      // to keep the shards in order and reduce buffer fragmentation
      auto parity_shard_offset = pad ? 1 : 0;
      util::buffer_t<char> shards {(parity_shard_offset + parity_shards) * blocksize};
      util::buffer_t<uint8_t *> shards_p {nr_shards};
      std::vector<platf::buffer_descriptor_t> payload_buffers;
      payload_buffers.reserve(2);

      // Point into the payload buffer for all except the final padded data shard
      auto next = std::begin(payload);
      for (auto x = 0; x < aligned_data_shards; ++x) {
        shards_p[x] = (uint8_t *) next;
        next += blocksize;
      }
      payload_buffers.emplace_back(std::begin(payload), aligned_data_shards * blocksize);

      // If the last data shard needs to be zero-padded, we must use the shards buffer
      if (pad) {
        shards_p[aligned_data_shards] = (uint8_t *) &shards[0];

        // GCC doesn't figure out that std::copy_n() can be replaced with memcpy() here
        // and ends up compiling a horribly slow element-by-element copy loop, so we
        // help it by using memcpy()/memset() directly.
        auto copy_len = std::min<size_t>(blocksize, std::end(payload) - next);
        std::memcpy(shards_p[aligned_data_shards], next, copy_len);
        if (copy_len < blocksize) {
          // Zero any additional space after the end of the payload
          std::memset(shards_p[aligned_data_shards] + copy_len, 0, blocksize - copy_len);
        }
      }

      // Add a payload buffer describing the shard buffer
      payload_buffers.emplace_back(std::begin(shards), shards.size());

      if (fecpercentage != 0) {
        // Point into our allocated buffer for the parity shards
        for (auto x = 0; x < parity_shards; ++x) {
          shards_p[data_shards + x] = (uint8_t *) &shards[(parity_shard_offset + x) * blocksize];
        }

        // packets = parity_shards + data_shards
        rs_t rs {reed_solomon_new(data_shards, parity_shards)};

        reed_solomon_encode(rs.get(), shards_p.begin(), nr_shards, blocksize);
      }

      return {
        data_shards,
        nr_shards,
        fecpercentage,
        blocksize,
        prefixsize,
        std::move(shards),
        util::buffer_t<char> {nr_shards * prefixsize},
        std::move(shards_p),
        std::move(payload_buffers),
      };
    }
  }  // namespace fec

  /**
   * @brief Combines two buffers and inserts new buffers at each slice boundary of the result.
   * @param insert_size The number of bytes to insert.
   * @param slice_size The number of bytes between insertions.
   * @param data1 The first data buffer.
   * @param data2 The second data buffer.
   */
  std::vector<uint8_t> concat_and_insert(uint64_t insert_size, uint64_t slice_size, const std::string_view &data1, const std::string_view &data2) {
    auto data_size = data1.size() + data2.size();
    auto pad = data_size % slice_size != 0;
    auto elements = data_size / slice_size + (pad ? 1 : 0);

    std::vector<uint8_t> result;
    result.resize(elements * insert_size + data_size);

    auto next = std::begin(data1);
    auto end = std::end(data1);
    for (auto x = 0; x < elements; ++x) {
      void *p = &result[x * (insert_size + slice_size)];

      // For the last iteration, only copy to the end of the data
      if (x == elements - 1) {
        slice_size = data_size - (x * slice_size);
      }

      // Test if this slice will extend into the next buffer
      if (next + slice_size > end) {
        // Copy the first portion from the first buffer
        auto copy_len = end - next;
        std::copy(next, end, (char *) p + insert_size);

        // Copy the remaining portion from the second buffer
        next = std::begin(data2);
        end = std::end(data2);
        std::copy(next, next + (slice_size - copy_len), (char *) p + copy_len + insert_size);
        next += slice_size - copy_len;
      } else {
        std::copy(next, next + slice_size, (char *) p + insert_size);
        next += slice_size;
      }
    }

    return result;
  }

  std::vector<uint8_t> replace(const std::string_view &original, const std::string_view &old, const std::string_view &_new) {
    std::vector<uint8_t> replaced;
    replaced.reserve(original.size() + _new.size() - old.size());

    auto begin = std::begin(original);
    auto end = std::end(original);
    auto next = std::search(begin, end, std::begin(old), std::end(old));

    std::copy(begin, next, std::back_inserter(replaced));
    if (next != end) {
      std::copy(std::begin(_new), std::end(_new), std::back_inserter(replaced));
      std::copy(next + old.size(), end, std::back_inserter(replaced));
    }

    return replaced;
  }

  /**
   * @brief Pass gamepad feedback data back to the client.
   * @param session The session object.
   * @param msg The message to pass.
   * @return 0 on success.
   */
  int send_feedback_msg(session_t *session, platf::gamepad_feedback_msg_t &msg) {
    if (!session->control.peer) {
      BOOST_LOG(warning) << "Couldn't send gamepad feedback data, still waiting for a client ping"sv;
      // Still waiting for the initial client ping
      return -1;
    }

    std::string payload;
    if (msg.type == platf::gamepad_feedback_e::rumble) {
      control_rumble_t plaintext;
      plaintext.header.type = packetTypes[IDX_RUMBLE_DATA];
      plaintext.header.payloadLength = sizeof(plaintext) - sizeof(control_header_v2);

      auto &data = msg.data.rumble;

      plaintext.useless = 0xC0FFEE;
      plaintext.id = util::endian::little(msg.id);
      plaintext.lowfreq = util::endian::little(data.lowfreq);
      plaintext.highfreq = util::endian::little(data.highfreq);

      BOOST_LOG(verbose) << "Rumble: "sv << msg.id << " :: "sv << util::hex(data.lowfreq).to_string_view() << " :: "sv << util::hex(data.highfreq).to_string_view();
      std::array<std::uint8_t, sizeof(control_encrypted_t) + crypto::cipher::round_to_pkcs7_padded(sizeof(plaintext)) + crypto::cipher::tag_size>
        encrypted_payload;

      payload = encode_control(session, util::view(plaintext), encrypted_payload);
    } else if (msg.type == platf::gamepad_feedback_e::rumble_triggers) {
      control_rumble_triggers_t plaintext;
      plaintext.header.type = packetTypes[IDX_RUMBLE_TRIGGER_DATA];
      plaintext.header.payloadLength = sizeof(plaintext) - sizeof(control_header_v2);

      auto &data = msg.data.rumble_triggers;

      plaintext.id = util::endian::little(msg.id);
      plaintext.left = util::endian::little(data.left_trigger);
      plaintext.right = util::endian::little(data.right_trigger);

      BOOST_LOG(verbose) << "Rumble triggers: "sv << msg.id << " :: "sv << util::hex(data.left_trigger).to_string_view() << " :: "sv << util::hex(data.right_trigger).to_string_view();
      std::array<std::uint8_t, sizeof(control_encrypted_t) + crypto::cipher::round_to_pkcs7_padded(sizeof(plaintext)) + crypto::cipher::tag_size>
        encrypted_payload;

      payload = encode_control(session, util::view(plaintext), encrypted_payload);
    } else if (msg.type == platf::gamepad_feedback_e::set_motion_event_state) {
      control_set_motion_event_t plaintext;
      plaintext.header.type = packetTypes[IDX_SET_MOTION_EVENT];
      plaintext.header.payloadLength = sizeof(plaintext) - sizeof(control_header_v2);

      auto &data = msg.data.motion_event_state;

      plaintext.id = util::endian::little(msg.id);
      plaintext.reportrate = util::endian::little(data.report_rate);
      plaintext.type = data.motion_type;

      BOOST_LOG(verbose) << "Motion event state: "sv << msg.id << " :: "sv << util::hex(data.report_rate).to_string_view() << " :: "sv << util::hex(data.motion_type).to_string_view();
      std::array<std::uint8_t, sizeof(control_encrypted_t) + crypto::cipher::round_to_pkcs7_padded(sizeof(plaintext)) + crypto::cipher::tag_size>
        encrypted_payload;

      payload = encode_control(session, util::view(plaintext), encrypted_payload);
    } else if (msg.type == platf::gamepad_feedback_e::set_rgb_led) {
      control_set_rgb_led_t plaintext;
      plaintext.header.type = packetTypes[IDX_SET_RGB_LED];
      plaintext.header.payloadLength = sizeof(plaintext) - sizeof(control_header_v2);

      auto &data = msg.data.rgb_led;

      plaintext.id = util::endian::little(msg.id);
      plaintext.r = data.r;
      plaintext.g = data.g;
      plaintext.b = data.b;

      BOOST_LOG(verbose) << "RGB: "sv << msg.id << " :: "sv << util::hex(data.r).to_string_view() << util::hex(data.g).to_string_view() << util::hex(data.b).to_string_view();
      std::array<std::uint8_t, sizeof(control_encrypted_t) + crypto::cipher::round_to_pkcs7_padded(sizeof(plaintext)) + crypto::cipher::tag_size>
        encrypted_payload;

      payload = encode_control(session, util::view(plaintext), encrypted_payload);
    } else if (msg.type == platf::gamepad_feedback_e::set_adaptive_triggers) {
      control_adaptive_triggers_t plaintext;
      plaintext.header.type = packetTypes[IDX_SET_ADAPTIVE_TRIGGERS];
      plaintext.header.payloadLength = sizeof(plaintext) - sizeof(control_header_v2);

      plaintext.id = util::endian::little(msg.id);
      plaintext.event_flags = msg.data.adaptive_triggers.event_flags;
      plaintext.type_left = msg.data.adaptive_triggers.type_left;
      std::ranges::copy(msg.data.adaptive_triggers.left, plaintext.left);
      plaintext.type_right = msg.data.adaptive_triggers.type_right;
      std::ranges::copy(msg.data.adaptive_triggers.right, plaintext.right);

      std::array<std::uint8_t, sizeof(control_encrypted_t) + crypto::cipher::round_to_pkcs7_padded(sizeof(plaintext)) + crypto::cipher::tag_size>
        encrypted_payload;

      payload = encode_control(session, util::view(plaintext), encrypted_payload);
    } else {
      BOOST_LOG(error) << "Unknown gamepad feedback message type"sv;
      return -1;
    }

    if (session->broadcast_ref->control_server.send(payload, session->control.peer)) {
      TUPLE_2D(port, addr, platf::from_sockaddr_ex((sockaddr *) &session->control.peer->address.address));
      BOOST_LOG(warning) << "Couldn't send gamepad feedback to ["sv << addr << ':' << port << ']';

      return -1;
    }

    return 0;
  }

  constexpr std::uint8_t apollo_hdr_frame_state_version = 1;
  constexpr std::uint8_t apollo_hdr_frame_state_flag_has_static_metadata = 1 << 0;
  constexpr std::uint8_t apollo_hdr_frame_state_flag_has_overlay_regions = 1 << 1;
  constexpr std::uint8_t apollo_hdr_overlay_region_flag_has_metadata = 1 << 0;

  std::string_view hdr_frame_content_name(video::hdr_frame_content_e content) {
    switch (content) {
      case video::hdr_frame_content_e::sdr:
        return "sdr"sv;
      case video::hdr_frame_content_e::full_frame_hdr:
        return "full-frame-hdr"sv;
      case video::hdr_frame_content_e::partial_hdr_overlay:
        return "partial-hdr-overlay"sv;
      default:
        return "unknown"sv;
    }
  }

  std::string build_hdr_frame_state_payload(
    std::uint32_t effective_from_frame_number,
    const video::hdr_frame_state_t &state
  ) {
    constexpr std::size_t max_control_payload_bytes = std::numeric_limits<std::uint16_t>::max();
    constexpr std::size_t max_total_packet_bytes = sizeof(control_header_v2) + max_control_payload_bytes;
    constexpr std::size_t max_overlay_regions_per_packet =
      (max_total_packet_bytes - sizeof(control_hdr_frame_state_v2_t)) / sizeof(control_hdr_overlay_region_v2_t);
    const auto region_count = std::min<std::size_t>(
      state.overlay_regions.size(),
      max_overlay_regions_per_packet
    );
    const auto total_size = sizeof(control_hdr_frame_state_v2_t) + region_count * sizeof(control_hdr_overlay_region_v2_t);
    std::string payload(total_size, '\0');

    auto *header = reinterpret_cast<control_hdr_frame_state_v2_t *>(payload.data());
    header->header.type = packetTypes[IDX_HDR_FRAME_STATE];
    header->header.payloadLength = static_cast<std::uint16_t>(total_size - sizeof(control_header_v2));
    header->version = apollo_hdr_frame_state_version;
    header->frameDynamicRange = static_cast<std::uint8_t>(state.content);
    header->flags =
      (state.has_static_metadata ? apollo_hdr_frame_state_flag_has_static_metadata : 0) |
      (region_count > 0 ? apollo_hdr_frame_state_flag_has_overlay_regions : 0);
    header->reserved = 0;
    header->effectiveFromFrameNumber = effective_from_frame_number;
    header->overlayRegionCount = static_cast<std::uint16_t>(region_count);
    header->reserved2 = 0;
    if (state.has_static_metadata) {
      header->staticMetadata = state.static_metadata;
    } else {
      std::memset(&header->staticMetadata, 0, sizeof(header->staticMetadata));
    }

    auto *serialized_region = reinterpret_cast<control_hdr_overlay_region_v2_t *>(header + 1);
    for (std::size_t index = 0; index < region_count; ++index) {
      const auto &region = state.overlay_regions[index];
      serialized_region[index].x = static_cast<std::uint16_t>(std::clamp(region.x, 0, 0xffff));
      serialized_region[index].y = static_cast<std::uint16_t>(std::clamp(region.y, 0, 0xffff));
      serialized_region[index].width = static_cast<std::uint16_t>(std::clamp(region.width, 0, 0xffff));
      serialized_region[index].height = static_cast<std::uint16_t>(std::clamp(region.height, 0, 0xffff));
      serialized_region[index].flags = region.has_metadata ? apollo_hdr_overlay_region_flag_has_metadata : 0;
      std::memset(serialized_region[index].reserved, 0, sizeof(serialized_region[index].reserved));
      if (region.has_metadata) {
        serialized_region[index].metadata = region.metadata;
      } else {
        std::memset(&serialized_region[index].metadata, 0, sizeof(serialized_region[index].metadata));
      }
    }

    return payload;
  }

  int send_hdr_frame_state(
    session_t *session,
    std::uint32_t effective_from_frame_number,
    const video::hdr_frame_state_t &state
  ) {
    if (!session->control.peer) {
      BOOST_LOG(warning) << "Couldn't send HDR frame state, still waiting for a client ping"sv;
      return -1;
    }

    auto plaintext = build_hdr_frame_state_payload(effective_from_frame_number, state);

    std::vector<std::uint8_t> encrypted_payload(
      sizeof(control_encrypted_t) +
      crypto::cipher::round_to_pkcs7_padded(plaintext.size()) +
      crypto::cipher::tag_size
    );

    auto payload = encode_control_dynamic(
      session,
      plaintext,
      encrypted_payload
    );
    if (session->broadcast_ref->control_server.send(payload, session->control.peer)) {
      TUPLE_2D(port, addr, platf::from_sockaddr_ex((sockaddr *) &session->control.peer->address.address));
      BOOST_LOG(warning) << "Couldn't send HDR frame state to ["sv << addr << ':' << port << ']';

      return -1;
    }

    BOOST_LOG(debug) << "Sent HDR frame state effective-from-frame="sv
                     << effective_from_frame_number
                     << " dynamic-range="sv
                     << hdr_frame_content_name(state.content)
                     << " regions="sv
                     << state.overlay_regions.size()
                     << " static-metadata="sv
                     << state.has_static_metadata;
    return 0;
  }

  void controlBroadcastThread(control_server_t *server) {
    server->map(packetTypes[IDX_PERIODIC_PING], [](session_t *session, const std::string_view &payload) {
      BOOST_LOG(verbose) << "type [IDX_PERIODIC_PING]"sv;
    });

    server->map(packetTypes[IDX_START_A], [&](session_t *session, const std::string_view &payload) {
      BOOST_LOG(debug) << "type [IDX_START_A]"sv;
    });

    server->map(packetTypes[IDX_START_B], [&](session_t *session, const std::string_view &payload) {
      BOOST_LOG(debug) << "type [IDX_START_B]"sv;
    });

    server->map(packetTypes[IDX_LOSS_STATS], [&](session_t *session, const std::string_view &payload) {
      int32_t *stats = (int32_t *) payload.data();
      auto count = stats[0];
      std::chrono::milliseconds t {stats[1]};

      auto lastGoodFrame = stats[3];

      BOOST_LOG(verbose)
        << "type [IDX_LOSS_STATS]"sv << std::endl
        << "---begin stats---" << std::endl
        << "loss count since last report [" << count << ']' << std::endl
        << "time in milli since last report [" << t.count() << ']' << std::endl
        << "last good frame [" << lastGoodFrame << ']' << std::endl
        << "---end stats---";
    });

    server->map(packetTypes[IDX_REQUEST_IDR_FRAME], [&](session_t *session, const std::string_view &payload) {
      BOOST_LOG(debug) << "type [IDX_REQUEST_IDR_FRAME]"sv;

      session->video.idr_events->raise(true);
    });

    server->map(packetTypes[IDX_INVALIDATE_REF_FRAMES], [&](session_t *session, const std::string_view &payload) {
      auto frames = (std::int64_t *) payload.data();
      auto firstFrame = frames[0];
      auto lastFrame = frames[1];

      BOOST_LOG(debug)
        << "type [IDX_INVALIDATE_REF_FRAMES]"sv << std::endl
        << "firstFrame [" << firstFrame << ']' << std::endl
        << "lastFrame [" << lastFrame << ']';

      session->video.invalidate_ref_frames_events->raise(std::make_pair(firstFrame, lastFrame));
    });

    server->map(packetTypes[IDX_EXEC_SERVER_CMD], [server](session_t *session, const std::string_view &payload) {
      BOOST_LOG(debug) << "type [IDX_EXEC_SERVER_CMD]"sv;

      if (!(session->permission & crypto::PERM::server_cmd)) {
        BOOST_LOG(debug) << "Permission Exec Server Cmd deined for [" << session->device_name << "]";
        return;
      }

      uint8_t cmdIndex = *(uint8_t*)payload.data();

      if (cmdIndex < config::runtime.server_cmds.size()) {
        const auto& cmd = config::runtime.server_cmds[cmdIndex];
        BOOST_LOG(info) << "Executing server command: " << cmd.cmd_name;

        auto exec_thread = std::thread([&cmd]{
          std::error_code ec;
          auto env = proc::proc.get_env();
          boost::filesystem::path working_dir = proc::find_working_directory(cmd.cmd_val, env);
          auto child = platf::run_command(cmd.elevated, true, cmd.cmd_val, working_dir, env, nullptr, ec, nullptr);

          if (ec) {
            BOOST_LOG(error) << "Failed to execute server command: " << ec.message();
          } else {
            child.detach();
          }
        });

        exec_thread.detach();
      } else {
        BOOST_LOG(error) << "Invalid server command index: " << (int)cmdIndex;
      }
    });

    server->map(packetTypes[IDX_SET_CLIPBOARD], [server](session_t *session, const std::string_view &payload) {
      BOOST_LOG(info) << "type [IDX_SET_CLIPBOARD]: "sv << payload << " size: " << payload.size();

      if (!(session->permission & crypto::PERM::clipboard_set)) {
        BOOST_LOG(debug) << "Permission Clipboard Set deined for [" << session->device_name << "]";
        return;
      }
    });

    server->map(packetTypes[IDX_FILE_TRANSFER_NONCE_REQUEST], [server](session_t *session, const std::string_view &payload) {
      BOOST_LOG(info) << "type [IDX_FILE_TRANSFER_NONCE_REQUEST]: "sv << payload << " size: " << payload.size();

      if (!(session->permission & crypto::PERM::file_upload)) {
        BOOST_LOG(debug) << "Permission File Upload deined for [" << session->device_name << "]";
        return;
      }
    });

    server->map(packetTypes[IDX_ENCRYPTED], [server](session_t *session, const std::string_view &payload) {
      BOOST_LOG(verbose) << "type [IDX_ENCRYPTED]"sv;

      auto header = (control_encrypted_p) (payload.data() - 2);

      auto length = util::endian::little(header->length);
      auto seq = util::endian::little(header->seq);

      if (length < (16 + 4 + 4)) {
        BOOST_LOG(warning) << "Control: Runt packet"sv;
        return;
      }

      auto tagged_cipher_length = length - 4;
      std::string_view tagged_cipher {(char *) header->payload(), (size_t) tagged_cipher_length};

      auto &cipher = session->control.cipher;
      auto &iv = session->control.incoming_iv;
      // We use the deterministic IV construction algorithm specified in NIST SP 800-38D
      // Section 8.2.1. The sequence number is our "invocation" field and the 'CC' in the
      // high bytes is the "fixed" field. Because each client provides their own unique
      // key, our values in the fixed field need only uniquely identify each independent
      // use of the client's key with AES-GCM in our code.
      //
      // The sequence number is 32 bits long which allows for 2^32 control stream messages
      // to be received from each client before the IV repeats.
      iv.resize(12);
      std::copy_n((uint8_t *) &seq, sizeof(seq), std::begin(iv));
      iv[10] = 'C';  // Client originated
      iv[11] = 'C';  // Control stream

      std::vector<uint8_t> plaintext;
      if (cipher.decrypt(tagged_cipher, plaintext, &iv)) {
        BOOST_LOG(warning) << "Dropping encrypted control packet after authentication tag verification failure"sv;
        return;
      }

      auto type = *(std::uint16_t *) plaintext.data();
      std::string_view next_payload {(char *) plaintext.data() + 4, plaintext.size() - 4};

      if (type == packetTypes[IDX_ENCRYPTED]) {
        BOOST_LOG(error) << "Bad packet type [IDX_ENCRYPTED] found"sv;
        session::stop(*session);
        return;
      }

      // Encrypted control packets already yielded plaintext, so input data can bypass the control dispatcher.
      if (type == packetTypes[IDX_INPUT_DATA]) {
        plaintext.erase(std::begin(plaintext), std::begin(plaintext) + 4);
        input::passthrough(session->input, std::move(plaintext), session->permission);
      } else {
        server->call(type, session, next_payload, true);
      }
    });

    // This thread handles latency-sensitive control messages
    platf::adjust_thread_priority(platf::thread_priority_e::critical);

    // Check for both the full shutdown event and the shutdown event for this
    // broadcast to ensure we can inform connected clients of our graceful
    // termination when we shut down.
    auto shutdown_event = mail::man->event<bool>(mail::shutdown);
    auto broadcast_shutdown_event = mail::man->event<bool>(mail::broadcast_shutdown);
    while (!shutdown_event->peek() && !broadcast_shutdown_event->peek()) {
      bool has_session_awaiting_peer = false;

      {
        auto lg = server->_sessions.lock();

        auto now = std::chrono::steady_clock::now();

        KITTY_WHILE_LOOP(auto pos = std::begin(*server->_sessions), pos != std::end(*server->_sessions), {
          // Don't perform additional session processing if we're shutting down
          if (shutdown_event->peek() || broadcast_shutdown_event->peek()) {
            break;
          }

          auto session = *pos;

          if (now > session->pingTimeout) {
            auto address = session->control.peer ? platf::from_sockaddr((sockaddr *) &session->control.peer->address.address) : session->control.expected_peer_address;
            BOOST_LOG(info) << address << ": Ping Timeout"sv;
            session::stop(*session);
          }

          if (session->state.load(std::memory_order_acquire) == session::state_e::STOPPING) {
            pos = server->_sessions->erase(pos);

            if (session->control.peer) {
              {
                auto ptslg = server->_peer_to_session.lock();
                server->_peer_to_session->erase(session->control.peer);
              }

              enet_peer_disconnect_now(session->control.peer, 0);
            }

            session->controlEnd.raise(true);
            continue;
          }

          // Remember if we have a session that's waiting for a peer to connect to the
          // control stream. This ensures the clients are properly notified even when
          // the app terminates before they finish connecting.
          if (!session->control.peer) {
            has_session_awaiting_peer = true;
          } else {
            auto &feedback_queue = session->control.feedback_queue;
            while (feedback_queue->peek()) {
              auto feedback_msg = feedback_queue->pop();

              send_feedback_msg(session, *feedback_msg);
            }

          }

          ++pos;
        })
      }

      // Don't break until any pending sessions either expire or connect
      if (proc::proc.running() == 0 && !has_session_awaiting_peer) {
        BOOST_LOG(info) << "Process terminated"sv;
        break;
      }

      server->iterate(150ms);
    }

    // Let all remaining connections know the server is shutting down
    // reason: graceful termination
    std::uint32_t reason = 0x80030023;

    control_terminate_t plaintext;
    plaintext.header.type = packetTypes[IDX_TERMINATION];
    plaintext.header.payloadLength = sizeof(plaintext.ec);
    plaintext.ec = util::endian::big<uint32_t>(reason);

    std::array<std::uint8_t, sizeof(control_encrypted_t) + crypto::cipher::round_to_pkcs7_padded(sizeof(plaintext)) + crypto::cipher::tag_size>
      encrypted_payload;

    auto lg = server->_sessions.lock();
    for (auto pos = std::begin(*server->_sessions); pos != std::end(*server->_sessions); ++pos) {
      auto session = *pos;

      // We may not have gotten far enough to have an ENet connection yet
      if (session->control.peer) {
        auto payload = encode_control(session, util::view(plaintext), encrypted_payload);

        if (server->send(payload, session->control.peer)) {
          TUPLE_2D(port, addr, platf::from_sockaddr_ex((sockaddr *) &session->control.peer->address.address));
          BOOST_LOG(warning) << "Couldn't send termination code to ["sv << addr << ':' << port << ']';
        }
      }

      session->shutdown_event->raise(true);
      session->controlEnd.raise(true);
    }

    server->flush();
  }

  void recvThread(broadcast_ctx_t &ctx) {
    std::map<av_session_id_t, message_queue_t> peer_to_video_session;
    std::map<av_session_id_t, message_queue_t> peer_to_audio_session;
    std::map<av_session_id_t, session_t *> peer_to_video_session_owner;
    std::map<av_session_id_t, session_t *> peer_to_audio_session_owner;

    auto &video_sock = ctx.video_sock;
    auto &audio_sock = ctx.audio_sock;

    auto &message_queue_queue = ctx.message_queue_queue;
    auto broadcast_shutdown_event = mail::man->event<bool>(mail::broadcast_shutdown);

    auto &io = ctx.io_context;

    udp::endpoint peer;

    std::array<char, 2048> buf[2];
    std::function<void(const boost::system::error_code, size_t)> recv_func[2];

    auto populate_peer_to_session = [&]() {
      while (message_queue_queue->peek()) {
        auto message_queue_opt = message_queue_queue->pop();
        auto &[socket_type, session_id, message_queue, session] = *message_queue_opt;

        switch (socket_type) {
          case socket_e::video:
            if (message_queue) {
              peer_to_video_session.emplace(session_id, message_queue);
              peer_to_video_session_owner[session_id] = session;
            } else {
              peer_to_video_session.erase(session_id);
              peer_to_video_session_owner.erase(session_id);
            }
            break;
          case socket_e::audio:
            if (message_queue) {
              peer_to_audio_session.emplace(session_id, message_queue);
              peer_to_audio_session_owner[session_id] = session;
            } else {
              peer_to_audio_session.erase(session_id);
              peer_to_audio_session_owner.erase(session_id);
            }
            break;
        }
      }
    };

    auto recv_func_init = [&](udp::socket &sock, int buf_elem, std::map<av_session_id_t, message_queue_t> &peer_to_session, std::map<av_session_id_t, session_t *> &peer_to_session_owner) {
      recv_func[buf_elem] = [&, buf_elem](const boost::system::error_code &ec, size_t bytes) {
        auto fg = util::fail_guard([&]() {
          sock.async_receive_from(asio::buffer(buf[buf_elem]), peer, 0, recv_func[buf_elem]);
        });

        auto type_str = buf_elem ? "AUDIO"sv : "VIDEO"sv;
        BOOST_LOG(verbose) << "Recv: "sv << peer.address().to_string() << ':' << peer.port() << " :: " << type_str;

        populate_peer_to_session();

        // No data, yet no error
        if (ec == boost::system::errc::connection_refused || ec == boost::system::errc::connection_reset) {
          return;
        }

        if (ec || !bytes) {
          BOOST_LOG(error) << "Couldn't receive data from udp socket: "sv << ec.message();
          return;
        }

        if (bytes >= sizeof(SS_PING)) {
          auto ping = (PSS_PING) buf[buf_elem].data();

          auto it = peer_to_session.find(std::string {ping->payload, sizeof(ping->payload)});
          if (it != std::end(peer_to_session)) {
            if (auto owner_it = peer_to_session_owner.find(std::string {ping->payload, sizeof(ping->payload)}); owner_it != std::end(peer_to_session_owner) && owner_it->second) {
              owner_it->second->pingTimeout = std::chrono::steady_clock::now() + config::stream.ping_timeout;
            }
            BOOST_LOG(debug) << "RAISE: "sv << peer.address().to_string() << ':' << peer.port() << " :: " << type_str;
            it->second->raise(peer, std::string {buf[buf_elem].data(), bytes});
          }
        }
      };
    };

    recv_func_init(video_sock, 0, peer_to_video_session, peer_to_video_session_owner);
    recv_func_init(audio_sock, 1, peer_to_audio_session, peer_to_audio_session_owner);

    video_sock.async_receive_from(asio::buffer(buf[0]), peer, 0, recv_func[0]);
    audio_sock.async_receive_from(asio::buffer(buf[1]), peer, 0, recv_func[1]);

    while (!broadcast_shutdown_event->peek()) {
      io.run();
    }
  }

  void videoBroadcastThread(udp::socket &sock) {
    auto shutdown_event = mail::man->event<bool>(mail::broadcast_shutdown);
    auto packets = mail::man->queue<video::packet_t>(mail::video_packets);
    auto video_epoch = std::chrono::steady_clock::now();

    // Video traffic is sent on this thread
    platf::adjust_thread_priority(platf::thread_priority_e::high);

    logging::min_max_avg_periodic_logger<double> frame_processing_latency_logger(debug, "Frame processing latency", "ms");

    logging::time_delta_periodic_logger frame_send_batch_latency_logger(debug, "Network: each send_batch() latency");
    logging::time_delta_periodic_logger frame_fec_latency_logger(debug, "Network: each FEC block latency");
    logging::time_delta_periodic_logger frame_network_latency_logger(debug, "Network: frame's overall network latency");

    crypto::aes_t iv(12);

    auto timer = platf::create_high_precision_timer();
    if (!timer || !*timer) {
      BOOST_LOG(error) << "Failed to create timer, aborting video broadcast thread";
      return;
    }

    auto ratecontrol_next_frame_start = std::chrono::steady_clock::now();

    while (auto packet = packets->pop()) {
      if (shutdown_event->peek()) {
        break;
      }

      frame_network_latency_logger.first_point_now();

      auto session = (session_t *) packet->channel_data;
      auto lowseq = session->video.lowseq;

      std::string_view payload {(char *) packet->data(), packet->data_size()};
      std::vector<uint8_t> payload_with_replacements;

      // Apply replacements on the packet payload before performing any other operations.
      // We need to know the final frame size to calculate the last packet size, and we
      // must avoid matching replacements against the frame header or any other non-video
      // part of the payload.
      if (packet->is_idr() && packet->replacements) {
        for (auto &replacement : *packet->replacements) {
          auto frame_old = replacement.old;
          auto frame_new = replacement._new;

          payload_with_replacements = replace(payload, frame_old, frame_new);
          payload = {(char *) payload_with_replacements.data(), payload_with_replacements.size()};
        }
      }

      if (session->control.peer &&
          video::dynamic_range_transport_uses_hdr_frame_state(video::effective_dynamic_range_transport(session->config.monitor)) &&
          session->config.monitor.sinkRequest.capability.supports_per_frame_hdr_metadata != 0) {
        auto frame_hdr_state = packet->hdr_frame_state.value_or(video::make_sdr_hdr_frame_state());
        if (frame_hdr_state.content == video::hdr_frame_content_e::partial_hdr_overlay &&
            session->config.monitor.sinkRequest.capability.supports_hdr_tile_overlay == 0) {
          frame_hdr_state = video::make_sdr_hdr_frame_state();
        }

        const bool should_send_frame_hdr_state =
          !session->control.last_sent_hdr_frame_state.has_value() ||
          !video::hdr_frame_state_equal(*session->control.last_sent_hdr_frame_state, frame_hdr_state) ||
          packet->is_idr();
        if (should_send_frame_hdr_state &&
            send_hdr_frame_state(session, static_cast<std::uint32_t>(packet->frame_index()), frame_hdr_state) == 0) {
          session->control.last_sent_hdr_frame_state = frame_hdr_state;
        }
      }

      video_short_frame_header_t frame_header = {};
      frame_header.headerType = 0x01;  // Short header type
      frame_header.frameType = packet->is_idr()                     ? 2 :
                               packet->after_ref_frame_invalidation ? 5 :
                                                                      1;
      frame_header.lastPayloadLen = (payload.size() + sizeof(frame_header)) % (session->config.packetsize - sizeof(NV_VIDEO_PACKET));
      if (frame_header.lastPayloadLen == 0) {
        frame_header.lastPayloadLen = session->config.packetsize - sizeof(NV_VIDEO_PACKET);
      }

      if (packet->frame_timestamp) {
        auto duration_to_latency = [](const std::chrono::steady_clock::duration &duration) {
          const auto duration_us = std::chrono::duration_cast<std::chrono::microseconds>(duration).count();
          return (uint16_t) std::clamp<decltype(duration_us)>((duration_us + 50) / 100, 0, std::numeric_limits<uint16_t>::max());
        };

        uint16_t latency = duration_to_latency(std::chrono::steady_clock::now() - *packet->frame_timestamp);
        frame_header.frame_processing_latency = latency;
        frame_processing_latency_logger.collect_and_log(latency / 10.);
      } else {
        frame_header.frame_processing_latency = 0;
      }

      auto fecPercentage = config::stream.fec_percentage;

      // Insert space for packet headers
      auto blocksize = session->config.packetsize + MAX_RTP_HEADER_SIZE;
      auto payload_blocksize = blocksize - sizeof(video_packet_raw_t);
      auto payload_new = concat_and_insert(sizeof(video_packet_raw_t), payload_blocksize, std::string_view {(char *) &frame_header, sizeof(frame_header)}, payload);

      payload = std::string_view {(char *) payload_new.data(), payload_new.size()};

      // There are 2 bits for FEC block count for a maximum of 4 FEC blocks
      constexpr auto MAX_FEC_BLOCKS = 4;

      // The max number of data shards per block is found by solving this system of equations for D:
      // D = 255 - P
      // P = D * F
      // which results in the solution:
      // D = 255 / (1 + F)
      // multiplied by 100 since F is the percentage as an integer:
      // D = (255 * 100) / (100 + F)
      auto max_data_shards_per_fec_block = (DATA_SHARDS_MAX * 100) / (100 + fecPercentage);

      // Compute the number of FEC blocks needed for this frame using the block size and max shards
      auto max_data_per_fec_block = max_data_shards_per_fec_block * blocksize;
      auto fec_blocks_needed = (payload.size() + (max_data_per_fec_block - 1)) / max_data_per_fec_block;

      // If the number of FEC blocks needed exceeds the protocol limit, turn off FEC for this frame.
      // For normal FEC percentages, this should only happen for enormous frames (over 800 packets at 20%).
      if (fec_blocks_needed > MAX_FEC_BLOCKS) {
        BOOST_LOG(warning) << "Skipping FEC for abnormally large encoded frame (needed "sv << fec_blocks_needed << " FEC blocks)"sv;
        fecPercentage = 0;
        fec_blocks_needed = MAX_FEC_BLOCKS;
      }

      std::array<std::string_view, MAX_FEC_BLOCKS> fec_blocks;
      decltype(fec_blocks)::iterator
        fec_blocks_begin = std::begin(fec_blocks),
        fec_blocks_end = std::begin(fec_blocks) + fec_blocks_needed;

      BOOST_LOG(verbose) << "Generating "sv << fec_blocks_needed << " FEC blocks"sv;

      // Align individual FEC blocks to blocksize
      auto unaligned_size = payload.size() / fec_blocks_needed;
      auto aligned_size = ((unaligned_size + (blocksize - 1)) / blocksize) * blocksize;

      // If we exceed the 10-bit FEC packet index (which means our frame exceeded 4096 packets),
      // the frame will be unrecoverable. Log an error for this case.
      if (aligned_size / blocksize >= 1024) {
        BOOST_LOG(error) << "Encoder produced a frame too large to send! Is the encoder broken? (needed "sv << (aligned_size / blocksize) << " packets)"sv;
      }

      // Split the data into aligned FEC blocks
      for (int x = 0; x < fec_blocks_needed; ++x) {
        if (x == fec_blocks_needed - 1) {
          // The last block must extend to the end of the payload
          fec_blocks[x] = payload.substr(x * aligned_size);
        } else {
          // Earlier blocks just extend to the next block offset
          fec_blocks[x] = payload.substr(x * aligned_size, aligned_size);
        }
      }

      try {
        // Use around 80% of 1Gbps          1Gbps            percent    ms     packet      byte
        size_t ratecontrol_packets_in_1ms = std::giga::num * 80 / 100 / 1000 / blocksize / 8;

        // Send less than 64K in a single batch.
        // On Windows, batches above 64K seem to bypass SO_SNDBUF regardless of its size,
        // appear in "Other I/O" and begin waiting for interrupts.
        // This gives inconsistent performance so we'd rather avoid it.
        size_t send_batch_size = std::max<std::size_t>(1, max_video_send_batch_bytes / blocksize);
        // Also don't exceed the platform packet-count cap, which can happen when the
        // client negotiates an unusually small packet size.
        // Generic Segmentation Offload on Linux can't do more than 64.
        send_batch_size = std::min(max_video_send_batch_packets, send_batch_size);
        const auto is_high_refresh = session->config.monitor.framerate >= high_refresh_low_latency_fps;
        const auto is_ultra_high_refresh = session->config.monitor.framerate >= ultra_high_refresh_low_latency_fps;
        if (is_high_refresh) {
          // High-refresh sessions are more sensitive to kernel-side packet clumping than
          // lower-refresh streams, so keep each send_batch() closer to a fraction of the
          // 1 ms pacing budget instead of always filling the largest batch we can.
          const auto send_batch_packets_cap =
            is_ultra_high_refresh ?
              ultra_high_refresh_send_batch_packets_cap :
              high_refresh_send_batch_packets_cap;
          const auto send_batch_divisor =
            is_ultra_high_refresh ?
              ultra_high_refresh_send_batch_divisor :
              high_refresh_send_batch_divisor;
          const auto high_refresh_send_batch_size = std::max<std::size_t>(
            1,
            std::min(
              send_batch_packets_cap,
              std::max<std::size_t>(1, ratecontrol_packets_in_1ms / send_batch_divisor)
            )
          );
          send_batch_size = std::min(send_batch_size, high_refresh_send_batch_size);
        }
        const auto pacing_quantum =
          is_ultra_high_refresh ?
            ultra_high_refresh_send_pacing_quantum :
          is_high_refresh ?
            high_refresh_send_pacing_quantum :
            default_send_pacing_quantum;
        const auto ratecontrol_packets_per_quantum = std::max<std::size_t>(
          1,
          is_ultra_high_refresh ?
            ratecontrol_packets_in_1ms / ultra_high_refresh_send_pacing_divisor :
          is_high_refresh ?
            ratecontrol_packets_in_1ms / high_refresh_send_pacing_divisor :
            ratecontrol_packets_in_1ms
        );

        // Don't ignore the last ratecontrol group of the previous frame
        auto ratecontrol_frame_start = std::max(ratecontrol_next_frame_start, std::chrono::steady_clock::now());

        size_t ratecontrol_frame_packets_sent = 0;
        size_t ratecontrol_group_packets_sent = 0;

        auto blockIndex = 0;
        std::for_each(fec_blocks_begin, fec_blocks_end, [&](std::string_view &current_payload) {
          auto packets = (current_payload.size() + (blocksize - 1)) / blocksize;

          for (int x = 0; x < packets; ++x) {
            auto *inspect = (video_packet_raw_t *) &current_payload[x * blocksize];

            inspect->packet.frameIndex = packet->frame_index();
            inspect->packet.streamPacketIndex = ((uint32_t) lowseq + x) << 8;

            inspect->packet.multiFecFlags = shadow_multi_fec_flags;
            inspect->packet.multiFecBlocks = (blockIndex << 4) | ((fec_blocks_needed - 1) << 6);

            inspect->packet.flags = FLAG_CONTAINS_PIC_DATA;
            if (x == 0) {
              inspect->packet.flags |= FLAG_SOF;
            }
            if (x == packets - 1) {
              inspect->packet.flags |= FLAG_EOF;
            }
          }

          frame_fec_latency_logger.first_point_now();
          // If video encryption is enabled, we allocate space for the encryption header before each shard
          auto shards = fec::encode(current_payload, blocksize, fecPercentage, session->config.minRequiredFecPackets, session->video.cipher ? sizeof(video_packet_enc_prefix_t) : 0);
          frame_fec_latency_logger.second_point_now_and_log();

          auto peer_address = session->video.peer.address();
          auto batch_info = platf::batched_send_info_t {
            shards.headers.begin(),
            shards.prefixsize,
            shards.payload_buffers,
            shards.blocksize,
            0,
            0,
            (uintptr_t) sock.native_handle(),
            peer_address,
            session->video.peer.port(),
            session->localAddress,
          };

          size_t next_shard_to_send = 0;

          // RTP video timestamps use a 90 KHz clock and the frame_timestamp from when the frame was captured
          // When a timestamp isn't available (duplicate frames), the timestamp from rate control is used instead.
          bool frame_is_dupe = false;
          if (!packet->frame_timestamp) {
            packet->frame_timestamp = ratecontrol_next_frame_start;
            frame_is_dupe = true;
          }
          using rtp_tick = std::chrono::duration<uint32_t, std::ratio<1, 90000>>;
          uint32_t timestamp = std::chrono::round<rtp_tick>(*packet->frame_timestamp - video_epoch).count();

          // set FEC info now that we know for sure what our percentage will be for this frame
          for (auto x = 0; x < shards.size(); ++x) {
            auto *inspect = (video_packet_raw_t *) shards.data(x);

            inspect->packet.fecInfo =
              (x << 12 |
               shards.data_shards << 22 |
               shards.percentage << 4);

            inspect->rtp.header = 0x80 | FLAG_EXTENSION;
            inspect->rtp.sequenceNumber = util::endian::big<uint16_t>(lowseq + x);
            inspect->rtp.timestamp = util::endian::big<uint32_t>(timestamp);

            inspect->packet.multiFecBlocks = (blockIndex << 4) | ((fec_blocks_needed - 1) << 6);
            inspect->packet.frameIndex = packet->frame_index();

            // Encrypt this shard if video encryption is enabled
            if (session->video.cipher) {
              // We use the deterministic IV construction algorithm specified in NIST SP 800-38D
              // Section 8.2.1. The sequence number is our "invocation" field and the 'V' in the
              // high bytes is the "fixed" field. Because each client provides their own unique
              // key, our values in the fixed field need only uniquely identify each independent
              // use of the client's key with AES-GCM in our code.
              //
              // The IV counter is 64 bits long which allows for 2^64 encrypted video packets
              // to be sent to each client before the IV repeats.
              std::copy_n((uint8_t *) &session->video.gcm_iv_counter, sizeof(session->video.gcm_iv_counter), std::begin(iv));
              iv[11] = 'V';  // Video stream
              session->video.gcm_iv_counter++;

              // Encrypt the target buffer in place
              auto *prefix = (video_packet_enc_prefix_t *) shards.prefix(x);
              prefix->frameNumber = packet->frame_index();
              std::copy(std::begin(iv), std::end(iv), prefix->iv);
              session->video.cipher->encrypt(std::string_view {(char *) inspect, (size_t) blocksize}, prefix->tag, (uint8_t *) inspect, &iv);
            }

            if (x - next_shard_to_send + 1 >= send_batch_size ||
                x + 1 == shards.size()) {
              // Do pacing within the frame.
              // Also trigger pacing before the first send_batch() of the frame
              // to account for the last send_batch() of the previous frame.
              if (ratecontrol_group_packets_sent >= ratecontrol_packets_per_quantum ||
                  ratecontrol_frame_packets_sent == 0) {
                auto due = ratecontrol_frame_start +
                           std::chrono::duration_cast<std::chrono::nanoseconds>(pacing_quantum) *
                             ratecontrol_frame_packets_sent / ratecontrol_packets_per_quantum;

                auto now = std::chrono::steady_clock::now();
                if (now < due) {
                  timer->sleep_for(due - now);
                }

                ratecontrol_group_packets_sent = 0;
              }

              size_t current_batch_size = x - next_shard_to_send + 1;
              batch_info.block_offset = next_shard_to_send;
              batch_info.block_count = current_batch_size;

              frame_send_batch_latency_logger.first_point_now();
              // Use a batched send if it's supported on this platform
              if (!platf::send_batch(batch_info)) {
                // Batched send is not available, so send each packet individually
                BOOST_LOG(verbose) << "Falling back to unbatched send"sv;
                for (auto y = 0; y < current_batch_size; y++) {
                  auto send_info = platf::send_info_t {
                    shards.prefix(next_shard_to_send + y),
                    shards.prefixsize,
                    shards.data(next_shard_to_send + y),
                    shards.blocksize,
                    (uintptr_t) sock.native_handle(),
                    peer_address,
                    session->video.peer.port(),
                    session->localAddress,
                  };

                  platf::send(send_info);
                }
              }
              frame_send_batch_latency_logger.second_point_now_and_log();

              ratecontrol_group_packets_sent += current_batch_size;
              ratecontrol_frame_packets_sent += current_batch_size;
              next_shard_to_send = x + 1;
            }
          }

          // remember this in case the next frame comes immediately
          ratecontrol_next_frame_start = ratecontrol_frame_start +
                                         std::chrono::duration_cast<std::chrono::nanoseconds>(pacing_quantum) *
                                           ratecontrol_frame_packets_sent / ratecontrol_packets_per_quantum;

          frame_network_latency_logger.second_point_now_and_log();

          BOOST_LOG(verbose) << "Sent Frame seq ["sv << packet->frame_index() << "] pts ["sv << timestamp
                             << "] shards ["sv << shards.size() << "/"sv << shards.percentage << "%]"sv
                             << (frame_is_dupe ? " Dupe" : "")
                             << (packet->is_idr() ? " Key" : "")
                             << (packet->after_ref_frame_invalidation ? " RFI" : "");

          ++blockIndex;
          lowseq += shards.size();
        });

        session->video.lowseq = lowseq;
      } catch (const std::exception &e) {
        BOOST_LOG(error) << "Broadcast video failed "sv << e.what();
        std::this_thread::sleep_for(100ms);
      }
    }

    shutdown_event->raise(true);
  }

  void audioBroadcastThread(udp::socket &sock) {
    auto shutdown_event = mail::man->event<bool>(mail::broadcast_shutdown);
    auto packets = mail::man->queue<audio::packet_t>(mail::audio_packets);

    audio_packet_t audio_packet;
    fec::rs_t rs {reed_solomon_new(RTPA_DATA_SHARDS, RTPA_FEC_SHARDS)};
    crypto::aes_t iv(16);

    // For unknown reasons, the RS parity matrix computed by our RS implementation
    // doesn't match the one Nvidia uses for audio data. I'm not exactly sure why,
    // but we can simply replace it with the matrix generated by OpenFEC which
    // works correctly. This is possible because the data and FEC shard count is
    // constant and known in advance.
    const unsigned char parity[] = {0x77, 0x40, 0x38, 0x0e, 0xc7, 0xa7, 0x0d, 0x6c};
    memcpy(rs.get()->p, parity, sizeof(parity));

    audio_packet.rtp.header = 0x80;
    audio_packet.rtp.packetType = 97;
    audio_packet.rtp.ssrc = 0;

    // Audio traffic is sent on this thread
    platf::adjust_thread_priority(platf::thread_priority_e::high);

    while (auto packet = packets->pop()) {
      if (shutdown_event->peek()) {
        break;
      }

      TUPLE_2D_REF(channel_data, packet_data, *packet);
      auto session = (session_t *) channel_data;

      auto sequenceNumber = session->audio.sequenceNumber;
      auto timestamp = session->audio.timestamp;

      *(std::uint32_t *) iv.data() = util::endian::big<std::uint32_t>(session->audio.avRiKeyId + sequenceNumber);

      auto &shards_p = session->audio.shards_p;

      auto bytes = encode_audio(session->config.encryptionFlagsEnabled & SS_ENC_AUDIO, packet_data, shards_p[sequenceNumber % RTPA_DATA_SHARDS], iv, session->audio.cipher);
      if (bytes < 0) {
        BOOST_LOG(error) << "Couldn't encode audio packet"sv;
        break;
      }

      BOOST_LOG(verbose) << "Audio [seq "sv << sequenceNumber << ", pts "sv << timestamp << "] ::  send..."sv;

      audio_packet.rtp.sequenceNumber = util::endian::big(sequenceNumber);
      audio_packet.rtp.timestamp = util::endian::big(timestamp);

      session->audio.sequenceNumber++;
      session->audio.timestamp += session->config.audio.packetDuration;

      auto peer_address = session->audio.peer.address();
      try {
        auto send_info = platf::send_info_t {
          (const char *) &audio_packet,
          sizeof(audio_packet),
          (const char *) shards_p[sequenceNumber % RTPA_DATA_SHARDS],
          (size_t) bytes,
          (uintptr_t) sock.native_handle(),
          peer_address,
          session->audio.peer.port(),
          session->localAddress,
        };
        platf::send(send_info);

        auto &fec_packet = session->audio.fec_packet;
        // initialize the FEC header at the beginning of the FEC block
        if (sequenceNumber % RTPA_DATA_SHARDS == 0) {
          fec_packet.fecHeader.baseSequenceNumber = util::endian::big(sequenceNumber);
          fec_packet.fecHeader.baseTimestamp = util::endian::big(timestamp);
        }

        // generate parity shards at the end of the FEC block
        if ((sequenceNumber + 1) % RTPA_DATA_SHARDS == 0) {
          reed_solomon_encode(rs.get(), shards_p.begin(), RTPA_TOTAL_SHARDS, bytes);

          for (auto x = 0; x < RTPA_FEC_SHARDS; ++x) {
            fec_packet.rtp.sequenceNumber = util::endian::big<std::uint16_t>(sequenceNumber + x + 1);
            fec_packet.fecHeader.fecShardIndex = x;

            auto send_info = platf::send_info_t {
              (const char *) &fec_packet,
              sizeof(fec_packet),
              (const char *) shards_p[RTPA_DATA_SHARDS + x],
              (size_t) bytes,
              (uintptr_t) sock.native_handle(),
              peer_address,
              session->audio.peer.port(),
              session->localAddress,
            };
            platf::send(send_info);
            BOOST_LOG(verbose) << "Audio FEC ["sv << (sequenceNumber & ~(RTPA_DATA_SHARDS - 1)) << ' ' << x << "] ::  send..."sv;
          }
        }
      } catch (const std::exception &e) {
        BOOST_LOG(error) << "Broadcast audio failed "sv << e.what();
        std::this_thread::sleep_for(100ms);
      }
    }

    shutdown_event->raise(true);
  }

  int start_broadcast(broadcast_ctx_t &ctx) {
    auto address_family = net::af_from_enum_string(config::runtime.address_family);
    auto protocol = address_family == net::IPV4 ? udp::v4() : udp::v6();
    auto control_port = net::map_port(CONTROL_PORT);
    auto video_port = net::map_port(VIDEO_STREAM_PORT);
    auto audio_port = net::map_port(AUDIO_STREAM_PORT);

    if (ctx.control_server.bind(address_family, control_port)) {
      BOOST_LOG(error) << "Couldn't bind Control server to port ["sv << control_port << "], likely another process already bound to the port"sv;

      return -1;
    }

    boost::system::error_code ec;
    ctx.video_sock.open(protocol, ec);
    if (ec) {
      BOOST_LOG(fatal) << "Couldn't open socket for Video server: "sv << ec.message();

      return -1;
    }

    // Set video socket send buffer size (SO_SENDBUF) to 1MB
    try {
      ctx.video_sock.set_option(boost::asio::socket_base::send_buffer_size(1024 * 1024));
    } catch (...) {
      BOOST_LOG(error) << "Failed to set video socket send buffer size (SO_SENDBUF)";
    }

    ctx.video_sock.bind(udp::endpoint(protocol, video_port), ec);
    if (ec) {
      BOOST_LOG(fatal) << "Couldn't bind Video server to port ["sv << video_port << "]: "sv << ec.message();

      return -1;
    }

    ctx.audio_sock.open(protocol, ec);
    if (ec) {
      BOOST_LOG(fatal) << "Couldn't open socket for Audio server: "sv << ec.message();

      return -1;
    }

    ctx.audio_sock.bind(udp::endpoint(protocol, audio_port), ec);
    if (ec) {
      BOOST_LOG(fatal) << "Couldn't bind Audio server to port ["sv << audio_port << "]: "sv << ec.message();

      return -1;
    }

    ctx.message_queue_queue = std::make_shared<message_queue_queue_t::element_type>(30);

    ctx.video_thread = std::thread {videoBroadcastThread, std::ref(ctx.video_sock)};
    ctx.audio_thread = std::thread {audioBroadcastThread, std::ref(ctx.audio_sock)};
    ctx.control_thread = std::thread {controlBroadcastThread, &ctx.control_server};

    ctx.recv_thread = std::thread {recvThread, std::ref(ctx)};

    return 0;
  }

  void end_broadcast(broadcast_ctx_t &ctx) {
    auto broadcast_shutdown_event = mail::man->event<bool>(mail::broadcast_shutdown);

    broadcast_shutdown_event->raise(true);

    auto video_packets = mail::man->queue<video::packet_t>(mail::video_packets);
    auto audio_packets = mail::man->queue<audio::packet_t>(mail::audio_packets);

    // Minimize delay stopping video/audio threads
    video_packets->stop();
    audio_packets->stop();

    ctx.message_queue_queue->stop();
    ctx.io_context.stop();

    ctx.video_sock.close();
    ctx.audio_sock.close();

    video_packets.reset();
    audio_packets.reset();

    BOOST_LOG(debug) << "Waiting for main listening thread to end..."sv;
    ctx.recv_thread.join();
    BOOST_LOG(debug) << "Waiting for main video thread to end..."sv;
    ctx.video_thread.join();
    BOOST_LOG(debug) << "Waiting for main audio thread to end..."sv;
    ctx.audio_thread.join();
    BOOST_LOG(debug) << "Waiting for main control thread to end..."sv;
    ctx.control_thread.join();
    BOOST_LOG(debug) << "All broadcasting threads ended"sv;

    broadcast_shutdown_event->reset();
  }

  int recv_ping(session_t *session, decltype(broadcast)::ptr_t ref, socket_e type, std::string_view expected_payload, udp::endpoint &peer, std::chrono::milliseconds timeout) {
    auto messages = std::make_shared<message_queue_t::element_type>(30);
    av_session_id_t session_id = std::string {expected_payload};

    ref->message_queue_queue->raise(message_queue_registration_t {type, session_id, messages, session});

    auto fg = util::fail_guard([&]() {
      messages->stop();

      // remove message queue from session
      ref->message_queue_queue->raise(message_queue_registration_t {type, session_id, nullptr, nullptr});
    });

    auto start_time = std::chrono::steady_clock::now();
    auto current_time = start_time;

    while (current_time - start_time < config::stream.ping_timeout) {
      auto delta_time = current_time - start_time;

      auto msg_opt = messages->pop(config::stream.ping_timeout - delta_time);
      if (!msg_opt) {
        break;
      }

      TUPLE_2D_REF(recv_peer, msg, *msg_opt);
      if (msg.find(expected_payload) != std::string::npos) {
        BOOST_LOG(debug) << "Received ping from "sv << recv_peer.address() << ':' << recv_peer.port() << " ["sv << util::hex_vec(msg) << ']';
      } else {
        BOOST_LOG(debug) << "Received non-ping from "sv << recv_peer.address() << ':' << recv_peer.port() << " ["sv << util::hex_vec(msg) << ']';
        current_time = std::chrono::steady_clock::now();
        continue;
      }

      // Update connection details.
      peer = recv_peer;
      return 0;
    }

    BOOST_LOG(error) << "Initial Ping Timeout"sv;
    return -1;
  }

  void videoThread(session_t *session) {
    auto fg = util::fail_guard([&]() {
      session::stop(*session);
    });

    while_starting_do_nothing(session->state);

    auto ref = broadcast.ref();
    BOOST_LOG(info) << "Video thread waiting for initial UDP ping"sv;
    auto ping_result = recv_ping(session, ref, socket_e::video, session->video.ping_payload, session->video.peer, config::stream.ping_timeout);
    if (ping_result < 0) {
      BOOST_LOG(error) << "Video thread failed while waiting for initial UDP ping"sv;
      return;
    }
    BOOST_LOG(info) << "Video thread established UDP peer ["sv << session->video.peer.address().to_string() << ':' << session->video.peer.port() << ']';

    // Enable local prioritization and QoS tagging on video traffic if requested by the client
    auto address = session->video.peer.address();
    session->video.qos = platf::enable_socket_qos(ref->video_sock.native_handle(), address, session->video.peer.port(), platf::qos_data_type_e::video, session->config.videoQosType != 0);

    BOOST_LOG(info) << "Starting video capture"sv;
    video::capture(session->mail, session->config.monitor, session);
    BOOST_LOG(info) << "Video capture ended"sv;
  }

  void audioThread(session_t *session) {
    auto fg = util::fail_guard([&]() {
      session::stop(*session);
    });

    while_starting_do_nothing(session->state);

    auto ref = broadcast.ref();
    auto error = recv_ping(session, ref, socket_e::audio, session->audio.ping_payload, session->audio.peer, config::stream.ping_timeout);
    if (error < 0) {
      return;
    }

    // Enable local prioritization and QoS tagging on audio traffic if requested by the client
    auto address = session->audio.peer.address();
    session->audio.qos = platf::enable_socket_qos(ref->audio_sock.native_handle(), address, session->audio.peer.port(), platf::qos_data_type_e::audio, session->config.audioQosType != 0);

    BOOST_LOG(debug) << "Start capturing Audio"sv;
    audio::capture(session->mail, session->config.audio, session);
  }

#ifdef __APPLE__
  namespace {
    uint32_t apollo_core_requested_display_id() {
      if (proc::proc.display_name.empty()) {
        return 0;
      }

      char *end_ptr = nullptr;
      const auto display_id = std::strtoul(proc::proc.display_name.c_str(), &end_ptr, 10);
      if (end_ptr && *end_ptr == '\0') {
        return static_cast<uint32_t>(display_id);
      }
      return 0;
    }

    ApolloCoreCaptureCodec apollo_core_requested_codec(int video_format) {
      switch (video_format) {
        case 0:
          return ApolloCoreCaptureCodecH264;
        case 1:
          return ApolloCoreCaptureCodecHEVC;
        default:
          return ApolloCoreCaptureCodecUnknown;
      }
    }

    std::string_view apollo_core_codec_name(ApolloCoreCaptureCodec codec) {
      switch (codec) {
        case ApolloCoreCaptureCodecH264:
          return "h264"sv;
        case ApolloCoreCaptureCodecHEVC:
          return "hevc"sv;
        case ApolloCoreCaptureCodecProResProxy:
          return "prores-proxy"sv;
        default:
          return "unknown"sv;
      }
    }

    std::string apollo_core_requested_streaming_profile() {
      auto streaming_profile = config::video.streaming_profile;
      std::transform(streaming_profile.begin(), streaming_profile.end(), streaming_profile.begin(), [](unsigned char ch) {
        return static_cast<char>(std::tolower(ch));
      });
      return streaming_profile;
    }

    ApolloCoreCaptureQueueProfile apollo_core_requested_queue_profile() {
      const auto streaming_profile = apollo_core_requested_streaming_profile();
      if (streaming_profile == "low-latency") {
        return ApolloCoreCaptureQueueProfileQ1;
      }
      if (streaming_profile == "max-quality") {
        return ApolloCoreCaptureQueueProfileQ4;
      }
      return ApolloCoreCaptureQueueProfileAuto;
    }

    std::string_view apollo_core_queue_profile_name(ApolloCoreCaptureQueueProfile queue_profile) {
      switch (queue_profile) {
        case ApolloCoreCaptureQueueProfileQ1:
          return "q1"sv;
        case ApolloCoreCaptureQueueProfileQ2:
          return "q2"sv;
        case ApolloCoreCaptureQueueProfileQ3:
          return "q3"sv;
        case ApolloCoreCaptureQueueProfileQ4:
          return "q4"sv;
        case ApolloCoreCaptureQueueProfileAuto:
          return "auto"sv;
        default:
          return "unknown"sv;
      }
    }

    std::string_view apollo_core_client_sink_gamut_name(int gamut) {
      switch (static_cast<video::client_sink_gamut_e>(gamut)) {
        case video::client_sink_gamut_e::srgb:
          return "srgb"sv;
        case video::client_sink_gamut_e::display_p3:
          return "display-p3"sv;
        case video::client_sink_gamut_e::rec2020:
          return "rec2020"sv;
        case video::client_sink_gamut_e::unknown:
        default:
          return "unknown"sv;
      }
    }

    std::string_view apollo_core_client_sink_transfer_name(int transfer) {
      switch (static_cast<video::client_sink_transfer_e>(transfer)) {
        case video::client_sink_transfer_e::sdr:
          return "sdr"sv;
        case video::client_sink_transfer_e::pq:
          return "pq"sv;
        case video::client_sink_transfer_e::hlg:
          return "hlg"sv;
        case video::client_sink_transfer_e::unknown:
        default:
          return "unknown"sv;
      }
    }

    std::string_view apollo_core_dynamic_range_transport_name(video::dynamic_range_transport_e transport) {
      switch (transport) {
        case video::dynamic_range_transport_e::sdr:
          return "sdr"sv;
        case video::dynamic_range_transport_e::full_frame_hdr:
          return "full-frame-hdr"sv;
        case video::dynamic_range_transport_e::frame_gated_hdr:
          return "frame-gated-hdr"sv;
        case video::dynamic_range_transport_e::sdr_base_hdr_overlay:
          return "sdr-base-hdr-overlay"sv;
        case video::dynamic_range_transport_e::unknown:
        default:
          return "unknown"sv;
      }
    }

    ApolloCoreHDRStaticMetadata apollo_core_hdr_static_metadata(const SS_HDR_METADATA &metadata) {
      return ApolloCoreHDRStaticMetadata {
        .red_primary_x = static_cast<int32_t>(metadata.displayPrimaries[0].x),
        .red_primary_y = static_cast<int32_t>(metadata.displayPrimaries[0].y),
        .green_primary_x = static_cast<int32_t>(metadata.displayPrimaries[1].x),
        .green_primary_y = static_cast<int32_t>(metadata.displayPrimaries[1].y),
        .blue_primary_x = static_cast<int32_t>(metadata.displayPrimaries[2].x),
        .blue_primary_y = static_cast<int32_t>(metadata.displayPrimaries[2].y),
        .white_point_x = static_cast<int32_t>(metadata.whitePoint.x),
        .white_point_y = static_cast<int32_t>(metadata.whitePoint.y),
        .max_display_luminance = static_cast<int32_t>(metadata.maxDisplayLuminance),
        .min_display_luminance = static_cast<int32_t>(metadata.minDisplayLuminance),
        .max_content_light_level = static_cast<int32_t>(metadata.maxContentLightLevel),
        .max_frame_average_light_level = static_cast<int32_t>(metadata.maxFrameAverageLightLevel),
        .max_full_frame_luminance = static_cast<int32_t>(metadata.maxFullFrameLuminance),
      };
    }

    ApolloCoreAudioCaptureSourceKind apollo_core_audio_source_kind(const audio::config_t &config) {
      return config.flags[audio::config_t::HOST_AUDIO] ?
               ApolloCoreAudioCaptureSourceKindSystemOutput :
               ApolloCoreAudioCaptureSourceKindMicrophone;
    }

    void mirror_apollo_core_capture_request(const ApolloCoreCaptureRequestSnapshot &snapshot) {
      platf::capture_request_mirror_state_t mirror_state {
        .generation = snapshot.generation,
        .video_generation = snapshot.video_generation,
        .audio_generation = snapshot.audio_generation,
        .video_requested = snapshot.video_requested,
        .audio_requested = snapshot.audio_requested,
        .display_id = snapshot.display_id,
        .codec = static_cast<int>(snapshot.codec),
        .preprocess_strategy = static_cast<int>(snapshot.preprocess_strategy),
        .queue_profile = static_cast<int>(snapshot.queue_profile),
        .show_cursor = snapshot.show_cursor,
        .target_frame_rate = snapshot.target_frame_rate,
        .target_video_bitrate_kbps = snapshot.target_video_bitrate_kbps,
        .requested_width = snapshot.requested_width,
        .requested_height = snapshot.requested_height,
        .sink_request = {
          .mode = {
            .hidpi = snapshot.sink_request.mode.hidpi,
            .scale_explicit = snapshot.sink_request.mode.scale_explicit,
            .mode_is_logical = snapshot.sink_request.mode.mode_is_logical,
            .scale_percent = snapshot.sink_request.mode.scale_percent,
          },
          .capability = {
            .gamut = snapshot.sink_request.capability.gamut,
            .transfer = snapshot.sink_request.capability.transfer,
            .current_edr_headroom = snapshot.sink_request.capability.current_edr_headroom,
            .potential_edr_headroom = snapshot.sink_request.capability.potential_edr_headroom,
            .current_peak_luminance_nits = snapshot.sink_request.capability.current_peak_luminance_nits,
            .potential_peak_luminance_nits = snapshot.sink_request.capability.potential_peak_luminance_nits,
            .supports_frame_gated_hdr = snapshot.sink_request.capability.supports_frame_gated_hdr,
            .supports_hdr_tile_overlay = snapshot.sink_request.capability.supports_hdr_tile_overlay,
            .supports_per_frame_hdr_metadata = snapshot.sink_request.capability.supports_per_frame_hdr_metadata,
          },
          .dynamic_range_transport = static_cast<video::dynamic_range_transport_e>(snapshot.sink_request.dynamic_range_transport),
        },
        .effective_display_state = {
          .gamut = snapshot.effective_display_state.gamut,
          .transfer = snapshot.effective_display_state.transfer,
        },
        .has_effective_hdr_metadata = snapshot.effective_display_state.has_hdr_static_metadata,
        .effective_hdr_metadata = {},
        .audio_source_kind = static_cast<int>(snapshot.audio_source_kind),
        .audio_excludes_current_process = snapshot.audio_excludes_current_process,
        .audio_sample_rate = snapshot.audio_sample_rate,
        .audio_channel_count = snapshot.audio_channel_count,
        .audio_frame_size = snapshot.audio_frame_size,
      };
      mirror_state.effective_hdr_metadata.displayPrimaries[0] = {
        static_cast<uint16_t>(snapshot.effective_display_state.hdr_static_metadata.red_primary_x),
        static_cast<uint16_t>(snapshot.effective_display_state.hdr_static_metadata.red_primary_y),
      };
      mirror_state.effective_hdr_metadata.displayPrimaries[1] = {
        static_cast<uint16_t>(snapshot.effective_display_state.hdr_static_metadata.green_primary_x),
        static_cast<uint16_t>(snapshot.effective_display_state.hdr_static_metadata.green_primary_y),
      };
      mirror_state.effective_hdr_metadata.displayPrimaries[2] = {
        static_cast<uint16_t>(snapshot.effective_display_state.hdr_static_metadata.blue_primary_x),
        static_cast<uint16_t>(snapshot.effective_display_state.hdr_static_metadata.blue_primary_y),
      };
      mirror_state.effective_hdr_metadata.whitePoint = {
        static_cast<uint16_t>(snapshot.effective_display_state.hdr_static_metadata.white_point_x),
        static_cast<uint16_t>(snapshot.effective_display_state.hdr_static_metadata.white_point_y),
      };
      mirror_state.effective_hdr_metadata.maxDisplayLuminance =
        static_cast<uint32_t>(snapshot.effective_display_state.hdr_static_metadata.max_display_luminance);
      mirror_state.effective_hdr_metadata.minDisplayLuminance =
        static_cast<uint32_t>(snapshot.effective_display_state.hdr_static_metadata.min_display_luminance);
      mirror_state.effective_hdr_metadata.maxContentLightLevel =
        static_cast<uint16_t>(snapshot.effective_display_state.hdr_static_metadata.max_content_light_level);
      mirror_state.effective_hdr_metadata.maxFrameAverageLightLevel =
        static_cast<uint16_t>(snapshot.effective_display_state.hdr_static_metadata.max_frame_average_light_level);
      mirror_state.effective_hdr_metadata.maxFullFrameLuminance =
        static_cast<uint16_t>(snapshot.effective_display_state.hdr_static_metadata.max_full_frame_luminance);
      platf::mirror_capture_request_state(mirror_state);
    }

    void publish_apollo_core_capture_request(const session_t &session) {
      if (session.config.monitor.input_only) {
        ApolloCoreCaptureRequestClear();
        platf::clear_capture_request_state_mirror();
        return;
      }

      const auto requested_display_id = apollo_core_requested_display_id();
      const auto requested_codec = apollo_core_requested_codec(session.config.monitor.videoFormat);
      const auto requested_queue_profile = apollo_core_requested_queue_profile();
      const auto requested_dynamic_range_transport =
        video::effective_dynamic_range_transport(session.config.monitor.sinkRequest.dynamic_range_transport);
      const auto negotiated_dynamic_range_transport =
        video::effective_dynamic_range_transport(session.config.monitor);
      const auto effective_display_state = platf::resolve_capture_request_effective_display_state(
        requested_display_id,
        negotiated_dynamic_range_transport,
        session.config.monitor.sinkRequest.capability.gamut,
        session.config.monitor.sinkRequest.capability.transfer
      );
      ApolloCoreHDRStaticMetadata effective_hdr_metadata {};
      bool has_effective_hdr_metadata = false;
      const bool hdr_stream = video::config_uses_hdr_stream(session.config.monitor);
      if (hdr_stream) {
        SS_HDR_METADATA hdr_metadata {};
        has_effective_hdr_metadata = platf::resolve_effective_display_hdr_metadata(
          effective_display_state.gamut,
          effective_display_state.transfer,
          session.config.monitor.sinkRequest.capability.current_edr_headroom,
          session.config.monitor.sinkRequest.capability.potential_edr_headroom,
          session.config.monitor.sinkRequest.capability.current_peak_luminance_nits,
          session.config.monitor.sinkRequest.capability.potential_peak_luminance_nits,
          hdr_metadata
        );
        if (has_effective_hdr_metadata) {
          effective_hdr_metadata = apollo_core_hdr_static_metadata(hdr_metadata);
        }
      }

      BOOST_LOG(info) << "Publishing macOS bridge capture request displayID="sv
                      << requested_display_id
                      << " codec="sv << apollo_core_codec_name(requested_codec)
                      << " streaming-profile="sv << apollo_core_requested_streaming_profile()
                      << " queue="sv << apollo_core_queue_profile_name(requested_queue_profile)
                      << " fps="sv << session.config.monitor.framerate
                      << " size="sv << session.config.monitor.width << "x"sv << session.config.monitor.height
                      << " requested-transport="sv
                      << apollo_core_dynamic_range_transport_name(requested_dynamic_range_transport)
                      << " negotiated-transport="sv
                      << apollo_core_dynamic_range_transport_name(negotiated_dynamic_range_transport)
                      << " hdr-stream="sv << hdr_stream
                      << " sink-gamut="sv
                      << apollo_core_client_sink_gamut_name(session.config.monitor.sinkRequest.capability.gamut)
                      << " sink-transfer="sv
                      << apollo_core_client_sink_transfer_name(session.config.monitor.sinkRequest.capability.transfer)
                      << " current-edr-headroom="sv
                      << session.config.monitor.sinkRequest.capability.current_edr_headroom
                      << " potential-edr-headroom="sv
                      << session.config.monitor.sinkRequest.capability.potential_edr_headroom
                      << " current-peak-nits="sv
                      << session.config.monitor.sinkRequest.capability.current_peak_luminance_nits
                      << " potential-peak-nits="sv
                      << session.config.monitor.sinkRequest.capability.potential_peak_luminance_nits
                      << " effective-gamut="sv
                      << apollo_core_client_sink_gamut_name(effective_display_state.gamut)
                      << " effective-transfer="sv
                      << apollo_core_client_sink_transfer_name(effective_display_state.transfer)
                      << " supports-frame-gated-hdr="sv
                      << (session.config.monitor.sinkRequest.capability.supports_frame_gated_hdr != 0)
                      << " supports-hdr-tile-overlay="sv
                      << (session.config.monitor.sinkRequest.capability.supports_hdr_tile_overlay != 0)
                      << " supports-per-frame-hdr-metadata="sv
                      << (session.config.monitor.sinkRequest.capability.supports_per_frame_hdr_metadata != 0)
                      << " effective-hdr-metadata="sv << has_effective_hdr_metadata;

      const ApolloCoreSinkRequest sink_request {
        .mode = {
          .hidpi = session.config.monitor.sinkRequest.mode.hidpi != 0,
          .scale_explicit = session.config.monitor.sinkRequest.mode.scale_explicit != 0,
          .mode_is_logical = session.config.monitor.sinkRequest.mode.mode_is_logical != 0,
          .scale_percent = session.config.monitor.sinkRequest.mode.scale_percent
        },
        .capability = {
          .gamut = session.config.monitor.sinkRequest.capability.gamut,
          .transfer = session.config.monitor.sinkRequest.capability.transfer,
          .current_edr_headroom = session.config.monitor.sinkRequest.capability.current_edr_headroom,
          .potential_edr_headroom = session.config.monitor.sinkRequest.capability.potential_edr_headroom,
          .current_peak_luminance_nits = session.config.monitor.sinkRequest.capability.current_peak_luminance_nits,
          .potential_peak_luminance_nits = session.config.monitor.sinkRequest.capability.potential_peak_luminance_nits,
          .supports_frame_gated_hdr = session.config.monitor.sinkRequest.capability.supports_frame_gated_hdr != 0,
          .supports_hdr_tile_overlay = session.config.monitor.sinkRequest.capability.supports_hdr_tile_overlay != 0,
          .supports_per_frame_hdr_metadata = session.config.monitor.sinkRequest.capability.supports_per_frame_hdr_metadata != 0
        },
        .dynamic_range_transport = static_cast<ApolloCoreDynamicRangeTransport>(requested_dynamic_range_transport)
      };
      const ApolloCoreEffectiveDisplayState effective_display_request {
        .gamut = effective_display_state.gamut,
        .transfer = effective_display_state.transfer,
        .has_hdr_static_metadata = has_effective_hdr_metadata,
        .hdr_static_metadata = effective_hdr_metadata
      };

      ApolloCoreCaptureRequestClear();
      ApolloCoreCaptureRequestPublishVideo(
        requested_display_id,
        requested_codec,
        ApolloCoreCapturePreprocessStrategyNone,
        requested_queue_profile,
        true,
        session.config.monitor.framerate,
        session.config.monitor.bitrate,
        session.config.monitor.width,
        session.config.monitor.height,
        sink_request,
        effective_display_request
      );

      if (config::audio.stream && !session.config.audio.input_only) {
        ApolloCoreCaptureRequestPublishAudio(
          apollo_core_audio_source_kind(session.config.audio),
          apollo_core_requested_display_id(),
          false,
          48000,
          session.config.audio.channels,
          session.config.audio.packetDuration * 48
        );
      }

      mirror_apollo_core_capture_request(ApolloCoreCaptureRequestCopySnapshot());
    }
  }  // namespace
#endif

  namespace session {
    std::atomic_uint running_sessions;

    state_e state(session_t &session) {
      return session.state.load(std::memory_order_relaxed);
    }

    inline bool send(session_t& session, const std::string_view &payload) {
      return session.broadcast_ref->control_server.send(payload, session.control.peer);
    }

    std::string uuid(const session_t& session) {
      return session.device_uuid;
    }

    bool uuid_match(const session_t &session, const std::string_view& uuid) {
      return session.device_uuid == uuid;
    }

    bool update_device_info(session_t& session, const std::string& name, const crypto::PERM& newPerm) {
      session.permission = newPerm;
      if (!(newPerm & crypto::PERM::_allow_view)) {
        BOOST_LOG(debug) << "Session: View permission revoked for [" << session.device_name << "], disconnecting...";
        graceful_stop(session);
        return true;
      }

      BOOST_LOG(debug) << "Session: Permission updated for [" << session.device_name << "]";

      if (session.device_name != name) {
        BOOST_LOG(debug) << "Session: Device name changed from [" << session.device_name << "] to [" << name << "]";
        session.device_name = name;
      }

      return false;
    }

    void stop(session_t &session) {
      while_starting_do_nothing(session.state);
      auto expected = state_e::RUNNING;
      auto already_stopping = !session.state.compare_exchange_strong(expected, state_e::STOPPING);
      if (already_stopping) {
        return;
      }

      session.shutdown_event->raise(true);
    }

    void graceful_stop(session_t& session) {
      while_starting_do_nothing(session.state);
      auto expected = state_e::RUNNING;
      auto already_stopping = !session.state.compare_exchange_strong(expected, state_e::STOPPING);
      if (already_stopping) {
        return;
      }

      // reason: graceful termination
      std::uint32_t reason = 0x80030023;

      control_terminate_t plaintext;
      plaintext.header.type = packetTypes[IDX_TERMINATION];
      plaintext.header.payloadLength = sizeof(plaintext.ec);
      plaintext.ec = util::endian::big<uint32_t>(reason);

      // We may not have gotten far enough to have an ENet connection yet
      if (session.control.peer) {
        std::array<std::uint8_t,
          sizeof(control_encrypted_t) + crypto::cipher::round_to_pkcs7_padded(sizeof(plaintext)) + crypto::cipher::tag_size>
          encrypted_payload;
        auto payload = stream::encode_control(&session, util::view(plaintext), encrypted_payload);

        if (send(session, payload)) {
          TUPLE_2D(port, addr, platf::from_sockaddr_ex((sockaddr *) &session.control.peer->address.address));
          BOOST_LOG(warning) << "Couldn't send termination code to ["sv << addr << ':' << port << ']';
        }
      }

      session.shutdown_event->raise(true);
      session.controlEnd.raise(true);
    }

    void join(session_t &session) {
      // Current Nvidia drivers have a bug where NVENC can deadlock the encoder thread with hardware-accelerated
      // GPU scheduling enabled. If this happens, we will terminate ourselves and the service can restart.
      // The alternative is that Sunshine can never start another session until it's manually restarted.
      auto task = []() {
        BOOST_LOG(fatal) << "Hang detected! Session failed to terminate in 10 seconds."sv;
        logging::log_flush();
        lifetime::debug_trap();
      };
      auto force_kill = task_pool.pushDelayed(task, 10s).task_id;
      auto fg = util::fail_guard([&force_kill]() {
        // Cancel the kill task if we manage to return from this function
        task_pool.cancel(force_kill);
      });

      BOOST_LOG(info) << "Waiting for video to end..."sv;
      session.videoThread.join();
      BOOST_LOG(info) << "Waiting for audio to end..."sv;
      session.audioThread.join();
      BOOST_LOG(info) << "Waiting for control to end..."sv;
      session.controlEnd.view();
      // Reset input on session stop to avoid stuck repeated keys
      BOOST_LOG(debug) << "Resetting Input..."sv;
      input::reset(session.input);

      if (!session.undo_cmds.empty()) {
        auto exec_thread = std::thread([cmd_list = session.undo_cmds]{
          for (auto &cmd : cmd_list) {
            std::error_code ec;
            auto env = proc::proc.get_env();
            boost::filesystem::path working_dir = proc::find_working_directory(cmd.cmd, env);
            auto child = platf::run_command(cmd.elevated, true, cmd.cmd, working_dir, env, nullptr, ec, nullptr);
            BOOST_LOG(info) << "Spawning client undo command ["sv << cmd.cmd << "] in ["sv << working_dir << ']';
            if (ec) {
              BOOST_LOG(warning) << "Couldn't spawn ["sv << cmd.cmd << "]: System: "sv << ec.message();
            } else {
              child.detach();
            }
          }
        });

        exec_thread.detach();
      }

      // If this is the last session, invoke the platform callbacks
      if (--running_sessions == 0) {
#ifdef __APPLE__
        ApolloCoreCaptureRequestClear();
        platf::clear_capture_request_state_mirror();
#endif
        bool revert_display_config {config::video.dd.config_revert_on_disconnect};
        proc::proc.on_stream_disconnected();

        if (proc::proc.running()) {
          proc::proc.pause();
        } else {
          // We have no app running and also no clients anymore.
          revert_display_config = true;
        }

        if (revert_display_config) {
          display_device::revert_configuration();
        }

        platf::streaming_will_stop();
      }

      BOOST_LOG(debug) << "Session ended"sv;
    }

    int start(session_t &session, const std::string &addr_string) {
      session.input = input::alloc(session.mail);

      session.broadcast_ref = broadcast.ref();
      if (!session.broadcast_ref) {
        return -1;
      }

      auto addr = net::parse_address(addr_string);
      if (!addr) {
        BOOST_LOG(error) << "Couldn't start session: invalid peer address ["sv << addr_string << ']';
        return -1;
      }

      if (!(session.config.mlFeatureFlags & ML_FF_SESSION_ID_V1)) {
        BOOST_LOG(error) << "Couldn't start session: Shadow transport requires session ID ping support"sv;
        return -1;
      }

      if (!(session.config.encryptionFlagsEnabled & SS_ENC_CONTROL_V2)) {
        BOOST_LOG(error) << "Couldn't start session: Shadow transport requires encrypted control stream v2 support"sv;
        return -1;
      }

      session.control.expected_peer_address = net::addr_to_normalized_string(*addr);
      BOOST_LOG(debug) << "Expecting incoming session connections from "sv << session.control.expected_peer_address;

      if (auto local_address = net::local_address_for_target(*addr)) {
        session.localAddress = *local_address;
      } else {
        BOOST_LOG(warning) << "Couldn't determine routed local source address for peer ["sv
                           << session.control.expected_peer_address << "] during session start"sv;
      }

      // Insert this session into the session list
      {
        auto lg = session.broadcast_ref->control_server._sessions.lock();
        session.broadcast_ref->control_server._sessions->push_back(&session);
      }

      session.video.peer.address(*addr);
      session.video.peer.port(0);

      session.audio.peer.address(*addr);
      session.audio.peer.port(0);

      session.pingTimeout = std::chrono::steady_clock::now() + config::stream.ping_timeout;

      session.audioThread = std::thread {audioThread, &session};
      session.videoThread = std::thread {videoThread, &session};

      session.state.store(state_e::RUNNING, std::memory_order_relaxed);

      // If this is the first session, invoke the platform callbacks
      if (++running_sessions == 1) {
        platf::streaming_will_start();
        proc::proc.resume();
      }

#ifdef __APPLE__
      publish_apollo_core_capture_request(session);
#endif

      if (!session.do_cmds.empty()) {
        auto exec_thread = std::thread([cmd_list = session.do_cmds]{
          for (auto &cmd : cmd_list) {
            std::error_code ec;
            auto env = proc::proc.get_env();
            boost::filesystem::path working_dir = proc::find_working_directory(cmd.cmd, env);
            auto child = platf::run_command(cmd.elevated, true, cmd.cmd, working_dir, env, nullptr, ec, nullptr);
            BOOST_LOG(info) << "Spawning client do command ["sv << cmd.cmd << "] in ["sv << working_dir << ']';
            if (ec) {
              BOOST_LOG(warning) << "Couldn't spawn ["sv << cmd.cmd << "]: System: "sv << ec.message();
            } else {
              child.detach();
            }
          }
        });

        exec_thread.detach();
      }

      return 0;
    }

    std::shared_ptr<session_t> alloc(config_t &config, rtsp_stream::launch_session_t &launch_session) {
      auto session = std::make_shared<session_t>();

      auto mail = std::make_shared<safe::mail_raw_t>();

      session->shutdown_event = mail->event<bool>(mail::shutdown);
      session->launch_session_id = launch_session.id;
      session->device_name = launch_session.device_name;
      session->device_uuid = launch_session.unique_id;
      session->permission = launch_session.perm;

      session->do_cmds = std::move(launch_session.client_do_cmds);
      session->undo_cmds = std::move(launch_session.client_undo_cmds);

      session->config = config;

      session->control.connect_data = launch_session.control_connect_data;
      session->control.feedback_queue = mail->queue<platf::gamepad_feedback_msg_t>(mail::gamepad_feedback);
      session->control.cipher = crypto::cipher::gcm_t {
        launch_session.gcm_key,
        false
      };

      session->video.idr_events = mail->event<bool>(mail::idr);
      session->video.invalidate_ref_frames_events = mail->event<std::pair<int64_t, int64_t>>(mail::invalidate_ref_frames);
      session->video.lowseq = 0;
      session->video.ping_payload = launch_session.av_ping_payload;
      if (config.encryptionFlagsEnabled & SS_ENC_VIDEO) {
        BOOST_LOG(info) << "Video encryption enabled"sv;
        session->video.cipher = crypto::cipher::gcm_t {
          launch_session.gcm_key,
          false
        };
        session->video.gcm_iv_counter = 0;
      }

      constexpr auto max_block_size = crypto::cipher::round_to_pkcs7_padded(2048);

      util::buffer_t<char> shards {RTPA_TOTAL_SHARDS * max_block_size};
      util::buffer_t<uint8_t *> shards_p {RTPA_TOTAL_SHARDS};

      for (auto x = 0; x < RTPA_TOTAL_SHARDS; ++x) {
        shards_p[x] = (uint8_t *) &shards[x * max_block_size];
      }

      // Audio FEC spans multiple audio packets,
      // therefore its session specific
      session->audio.shards = std::move(shards);
      session->audio.shards_p = std::move(shards_p);

      session->audio.fec_packet.rtp.header = 0x80;
      session->audio.fec_packet.rtp.packetType = 127;
      session->audio.fec_packet.rtp.timestamp = 0;
      session->audio.fec_packet.rtp.ssrc = 0;

      session->audio.fec_packet.fecHeader.payloadType = 97;
      session->audio.fec_packet.fecHeader.ssrc = 0;

      session->audio.cipher = crypto::cipher::cbc_t {
        launch_session.gcm_key,
        true
      };

      session->audio.ping_payload = launch_session.av_ping_payload;
      session->audio.avRiKeyId = util::endian::big(*(std::uint32_t *) launch_session.iv.data());
      session->audio.sequenceNumber = 0;
      session->audio.timestamp = 0;

      session->control.peer = nullptr;
      session->state.store(state_e::STOPPED, std::memory_order_relaxed);

      session->mail = std::move(mail);

      return session;
    }
  }  // namespace session
}  // namespace stream
