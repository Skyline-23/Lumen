use super::*;

fn session_offer() -> String {
    r#"{"version":1,"displayMode":{"scalePercent":200,"hiDPI":true,"logical":true},"sink":{"gamut":"display-p3","transfer":"pq","currentEDRHeadroom":2.4,"potentialEDRHeadroom":16,"currentPeakNits":240,"potentialPeakNits":1600},"capabilities":{"frameGatedHDR":true,"hdrTileOverlay":false,"perFrameHDRMetadata":true},"requestedDynamicRange":"frame-gated-hdr"}"#.to_owned()
}

fn canonical_query() -> Vec<(String, String)> {
    [
        ("appid", "881448767"),
        ("mode", "3512x2290x120"),
        ("sops", "1"),
        ("rikey", "00112233445566778899aabbccddeeff"),
        ("rikeyid", "66051"),
        ("localAudioPlayMode", "0"),
        ("audioChannelMode", "7.1"),
        ("enhancedAudioQuality", "1"),
        ("gcmap", "1"),
    ]
    .into_iter()
    .map(|(name, value)| (name.to_owned(), value.to_owned()))
    .chain([("lumenSessionOffer".to_owned(), session_offer())])
    .chain([("virtualDisplay".to_owned(), "1".to_owned())])
    .collect()
}

#[test]
fn parses_the_exact_shadow_launch_shape_into_one_typed_plan() {
    let plan = parse_launch_request(&canonical_query()).unwrap();
    assert_eq!(plan.application_id, 881_448_767);
    assert_eq!(
        plan.display_mode,
        LaunchDisplayMode {
            width: 3512,
            height: 2290,
            frames_per_second: 120,
        }
    );
    assert_eq!(
        plan.remote_input_key,
        [
            0x00, 0x11, 0x22, 0x33, 0x44, 0x55, 0x66, 0x77, 0x88, 0x99, 0xaa, 0xbb, 0xcc, 0xdd,
            0xee, 0xff
        ]
    );
    assert_eq!(plan.remote_input_key_id, 66_051);
    assert!(!plan.play_audio_on_host);
    assert_eq!(plan.audio.channel_count, 8);
    assert!(plan.audio.enhanced_audio_quality);
    assert!(plan.virtual_display);
    assert_eq!(plan.session_offer.version, 1);
    assert_eq!(plan.session_offer.scale_percent, 200);
}

#[test]
fn ffi_returns_the_same_complete_typed_plan() {
    let query = canonical_query();
    let fields = query
        .iter()
        .map(|(name, value)| LumenLaunchQueryField {
            name: name.as_ptr(),
            name_length: name.len(),
            value: value.as_ptr(),
            value_length: value.len(),
        })
        .collect::<Vec<_>>();
    let mut plan = LumenLaunchRequestPlan::from(parse_launch_request(&query).unwrap());
    plan.application_id = 0;
    assert_eq!(
        unsafe { lumen_engine_parse_launch_request(fields.as_ptr(), fields.len(), &mut plan) },
        LumenEngineStatus::Ok
    );
    assert_eq!(plan.application_id, 881_448_767);
    assert_eq!(plan.width, 3512);
    assert_eq!(plan.height, 2290);
    assert_eq!(plan.frames_per_second, 120);
    assert_eq!(plan.remote_input_key_id, 66_051);
    assert_eq!(plan.audio.channel_count, 8);
    assert!(plan.audio.enhanced_audio_quality);
    assert!(plan.virtual_display);
    assert_eq!(plan.session_offer.scale_percent, 200);
}

#[test]
fn ffi_rejects_null_empty_non_utf8_and_incomplete_fields() {
    let mut plan = LumenLaunchRequestPlan::from(parse_launch_request(&canonical_query()).unwrap());
    assert_eq!(
        unsafe { lumen_engine_parse_launch_request(std::ptr::null(), 1, &mut plan) },
        LumenEngineStatus::InvalidArgument
    );
    assert_eq!(
        unsafe { lumen_engine_parse_launch_request(std::ptr::null(), 0, &mut plan) },
        LumenEngineStatus::InvalidArgument
    );
    let invalid = [0xff];
    let field = LumenLaunchQueryField {
        name: invalid.as_ptr(),
        name_length: invalid.len(),
        value: invalid.as_ptr(),
        value_length: invalid.len(),
    };
    assert_eq!(
        unsafe { lumen_engine_parse_launch_request(&field, 1, &mut plan) },
        LumenEngineStatus::InvalidArgument
    );
}

#[test]
fn rejects_aliases_unknowns_duplicates_and_malformed_values() {
    let mut missing = canonical_query();
    missing.retain(|(name, _)| name != "enhancedAudioQuality");
    assert_eq!(
        parse_launch_request(&missing).unwrap_err(),
        LaunchRequestError {
            code: LaunchRequestErrorCode::MissingField,
            field: "enhancedAudioQuality".to_owned(),
        }
    );

    let mut app_uuid = canonical_query();
    app_uuid.retain(|(name, _)| name != "appid");
    app_uuid.push(("appuuid".into(), "legacy".into()));
    assert_eq!(
        parse_launch_request(&app_uuid).unwrap_err().code,
        LaunchRequestErrorCode::UnknownField
    );

    let mut duplicate = canonical_query();
    duplicate.push(("enhancedAudioQuality".into(), "0".into()));
    assert_eq!(
        parse_launch_request(&duplicate).unwrap_err().code,
        LaunchRequestErrorCode::DuplicateField
    );

    for (field, value) in [
        ("mode", "3512x2290x0"),
        ("rikey", "not-a-key"),
        ("audioChannelMode", "8"),
        ("enhancedAudioQuality", "true"),
        ("audioChannelMode", "surround-7.1"),
        ("sops", "0"),
        ("gcmap", "0"),
        ("virtualDisplay", "0"),
    ] {
        let mut query = canonical_query();
        query.iter_mut().find(|(name, _)| name == field).unwrap().1 = value.to_owned();
        assert_eq!(
            parse_launch_request(&query).unwrap_err().code,
            LaunchRequestErrorCode::InvalidValue,
            "{field}"
        );
    }
}
