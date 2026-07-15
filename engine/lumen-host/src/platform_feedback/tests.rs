use super::*;

fn wire(kind: LumenHostPlatformControlFeedbackKind) -> LumenHostPlatformControlFeedback {
    LumenHostPlatformControlFeedback {
        kind,
        control_connect_data: 66_051,
        controller_id: 2,
        value_a: 3,
        value_b: 4,
        report_rate: 120,
        motion_type: 5,
        red: 6,
        green: 7,
        blue: 8,
        event_flags: 9,
        type_left: 10,
        type_right: 11,
        left: [12; ADAPTIVE_TRIGGER_BYTES],
        right: [13; ADAPTIVE_TRIGGER_BYTES],
    }
}

#[test]
fn converts_every_native_feedback_variant_and_preserves_session_routing() {
    let feedback = [
        PlatformControlFeedback::from(wire(LumenHostPlatformControlFeedbackKind::Rumble)),
        PlatformControlFeedback::from(wire(LumenHostPlatformControlFeedbackKind::RumbleTriggers)),
        PlatformControlFeedback::from(wire(LumenHostPlatformControlFeedbackKind::MotionEvent)),
        PlatformControlFeedback::from(wire(LumenHostPlatformControlFeedbackKind::RgbLed)),
        PlatformControlFeedback::from(wire(LumenHostPlatformControlFeedbackKind::AdaptiveTriggers)),
    ];
    assert!(feedback
        .iter()
        .all(|feedback| feedback.control_connect_data() == 66_051));
    assert!(matches!(
        feedback[0],
        PlatformControlFeedback::Rumble {
            controller_id: 2,
            low_frequency: 3,
            high_frequency: 4,
            ..
        }
    ));
    let PlatformControlFeedback::AdaptiveTriggers {
        event_flags,
        type_left,
        type_right,
        left,
        right,
        ..
    } = feedback[4]
    else {
        panic!("expected adaptive trigger feedback");
    };
    assert_eq!((event_flags, type_left, type_right), (9, 10, 11));
    assert_eq!(left, [12; ADAPTIVE_TRIGGER_BYTES]);
    assert_eq!(right, [13; ADAPTIVE_TRIGGER_BYTES]);
}
