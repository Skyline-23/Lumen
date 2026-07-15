use super::*;

#[test]
fn rejects_mismatched_configuration_header_before_acknowledgement_or_media_output() {
    // Given: a valid H.264 SPS wrapped by an avcC header claiming the wrong profile.
    let receiver = UdpSocket::bind((Ipv4Addr::LOCALHOST, 0)).unwrap();
    receiver
        .set_read_timeout(Some(Duration::from_millis(25)))
        .unwrap();
    let sender_socket = UdpSocket::bind((Ipv4Addr::LOCALHOST, 0)).unwrap();
    let selected = crate::media::native_video::test_fixtures::H264_420;
    let mut fixture_normalizer = NativeVideoBitstreamNormalizer::new(selected);
    let normalized = fixture_normalizer
        .normalize(crate::media::native_video::test_fixtures::encoded_frame(
            selected,
        ))
        .unwrap();
    let mut record = normalized
        .new_configuration
        .unwrap()
        .decoder_configuration_record;
    record[1] = 77;
    let delivery = VideoDeliveryState {
        video_format: selected,
        acknowledged_configuration_id: Some(1),
        session_epoch: 7,
        path_id: 1,
        policy_revision: 1,
        maximum_datagram_payload: 1_200,
        endpoint: receiver.local_addr().unwrap(),
        encryption_key: [0x22; 16],
        fec_percentage: 0,
    };
    let frame = crate::PlatformEncodedVideoFrame {
        payload: vec![0, 0, 0, 1, 0x65, 0x88],
        decoder_configuration_record: Some(record),
        presentation_time_90khz: 90_000,
        key_frame: true,
    };
    let mut sender = VideoSenderState::default();

    // When: the supplied configuration reaches the local sender boundary.
    let result = send_video_frame(&sender_socket, &delivery, &mut sender, frame);

    // Then: it is neither staged for acknowledgement nor emitted as media.
    assert_eq!(
        result,
        Err("H.264 decoder configuration header disagrees with its SPS".to_owned())
    );
    assert!(sender.pending_frame.is_none());
    let mut datagram = [0_u8; 2_048];
    assert!(matches!(
        receiver.recv_from(&mut datagram).unwrap_err().kind(),
        io::ErrorKind::WouldBlock | io::ErrorKind::TimedOut
    ));
}
