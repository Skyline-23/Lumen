use std::collections::VecDeque;
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

use core_graphics::event::CGEventFlags;

use super::*;

#[derive(Clone, Debug, Eq, PartialEq)]
enum PostedEvent {
    Key {
        hid_usage: u16,
        pressed: bool,
        modifiers: u8,
        repeat: bool,
    },
    Button {
        button: u8,
        pressed: bool,
        click_state: u32,
    },
}

struct RecordingPoster {
    outcomes: Mutex<VecDeque<Result<(), String>>>,
    events: Mutex<Vec<PostedEvent>>,
    button_locations: Mutex<Vec<(f64, f64)>>,
}

impl RecordingPoster {
    fn new(outcomes: impl IntoIterator<Item = Result<(), String>>) -> Self {
        Self {
            outcomes: Mutex::new(outcomes.into_iter().collect()),
            events: Mutex::new(Vec::new()),
            button_locations: Mutex::new(Vec::new()),
        }
    }

    fn events(&self) -> Vec<PostedEvent> {
        self.events.lock().unwrap().clone()
    }

    fn button_locations(&self) -> Vec<(f64, f64)> {
        self.button_locations.lock().unwrap().clone()
    }

    fn record(&self, event: PostedEvent) -> Result<(), String> {
        self.events.lock().unwrap().push(event);
        self.outcomes.lock().unwrap().pop_front().unwrap_or(Ok(()))
    }
}

impl MacInputEventPoster for RecordingPoster {
    fn post_key(
        &self,
        hid_usage: u16,
        pressed: bool,
        modifiers: u8,
        repeat: bool,
    ) -> Result<(), String> {
        self.record(PostedEvent::Key {
            hid_usage,
            pressed,
            modifiers,
            repeat,
        })
    }

    fn pointer_location(&self) -> Result<CGPoint, String> {
        Ok(CGPoint::new(120.0, 80.0))
    }

    fn post_button(
        &self,
        button: u8,
        pressed: bool,
        click_state: u32,
        location: CGPoint,
    ) -> Result<(), String> {
        self.button_locations
            .lock()
            .unwrap()
            .push((location.x, location.y));
        self.record(PostedEvent::Button {
            button,
            pressed,
            click_state,
        })
    }
}

#[test]
fn positioned_button_uses_exact_motion_target_without_pointer_requery() {
    let poster = Arc::new(RecordingPoster::new([]));
    let input = MacNativeInput::with_poster(poster.clone());
    let mut state = MacInputState::default();

    input
        .handle_pointer_button(&mut state, 1, true, Some(CGPoint::new(321.0, 654.0)))
        .unwrap();

    assert_eq!(poster.button_locations(), [(321.0, 654.0)]);
}

#[test]
fn click_tracker_marks_two_matching_pairs_as_single_then_double_clicks() {
    let mut tracker = MacClickTracker::default();
    let start = Instant::now();
    let location = CGPoint::new(120.0, 80.0);
    let interval = Duration::from_millis(500);

    let first = tracker.begin(1, location, start, interval);
    tracker.finish(1, first);
    let second = tracker.begin(1, location, start + Duration::from_millis(100), interval);
    tracker.finish(1, second);

    assert_eq!(first, 1);
    assert_eq!(second, 2);
}

#[test]
fn click_tracker_resets_after_interval_or_pointer_movement() {
    let mut tracker = MacClickTracker::default();
    let start = Instant::now();
    let location = CGPoint::new(120.0, 80.0);
    let interval = Duration::from_millis(500);

    let first = tracker.begin(1, location, start, interval);
    tracker.finish(1, first);
    let late = tracker.begin(1, location, start + Duration::from_millis(700), interval);
    tracker.finish(1, late);
    let moved = tracker.begin(
        1,
        CGPoint::new(128.0, 80.0),
        start + Duration::from_millis(800),
        interval,
    );

    assert_eq!(late, 1);
    assert_eq!(moved, 1);
}

#[test]
fn click_location_policy_applies_tolerance_per_axis() {
    let origin = CGPoint::new(120.0, 80.0);

    assert!(click_locations_match(origin, CGPoint::new(125.0, 85.0)));
    assert!(!click_locations_match(origin, CGPoint::new(125.01, 80.0)));
    assert!(!click_locations_match(origin, CGPoint::new(120.0, 85.01)));
}

#[test]
fn click_tracker_keeps_button_sequences_independent() {
    let mut tracker = MacClickTracker::default();
    let start = Instant::now();
    let location = CGPoint::new(120.0, 80.0);
    let interval = Duration::from_millis(500);

    let left = tracker.begin(1, location, start, interval);
    tracker.finish(1, left);
    let right = tracker.begin(3, location, start + Duration::from_millis(30), interval);
    tracker.finish(3, right);
    let left_again = tracker.begin(1, location, start + Duration::from_millis(100), interval);

    assert_eq!(left, 1);
    assert_eq!(right, 1);
    assert_eq!(left_again, 2);
}

#[test]
fn continuous_scroll_maps_gesture_and_momentum_phases_without_quantization_state() {
    assert_eq!(mac_scroll_phases(NativeScrollPhase::Began), (1, 0));
    assert_eq!(mac_scroll_phases(NativeScrollPhase::Changed), (2, 0));
    assert_eq!(mac_scroll_phases(NativeScrollPhase::Ended), (4, 0));
    assert_eq!(mac_scroll_phases(NativeScrollPhase::Cancelled), (8, 0));
    assert_eq!(mac_scroll_phases(NativeScrollPhase::MomentumBegan), (0, 1));
    assert_eq!(
        mac_scroll_phases(NativeScrollPhase::MomentumChanged),
        (0, 2)
    );
    assert_eq!(mac_scroll_phases(NativeScrollPhase::MomentumEnded), (0, 3));
}

#[test]
fn rapid_left_pairs_emit_matching_click_state_on_down_and_up() {
    let poster = Arc::new(RecordingPoster::new([Ok(()), Ok(()), Ok(()), Ok(())]));
    let input =
        MacNativeInput::with_poster_and_click_interval(poster.clone(), Duration::from_millis(500));
    let press = PlatformNativeInputEvent::PointerButton {
        pointer_id: 0,
        button: 1,
        pressed: true,
        absolute_position: None,
    };
    let release = PlatformNativeInputEvent::PointerButton {
        pointer_id: 0,
        button: 1,
        pressed: false,
        absolute_position: None,
    };

    input.handle(21, press.clone()).unwrap();
    input.handle(21, release.clone()).unwrap();
    input.handle(21, press).unwrap();
    input.handle(21, release).unwrap();

    assert_eq!(
        poster.events(),
        vec![
            PostedEvent::Button {
                button: 1,
                pressed: true,
                click_state: 1,
            },
            PostedEvent::Button {
                button: 1,
                pressed: false,
                click_state: 1,
            },
            PostedEvent::Button {
                button: 1,
                pressed: true,
                click_state: 2,
            },
            PostedEvent::Button {
                button: 1,
                pressed: false,
                click_state: 2,
            },
        ]
    );
}

#[test]
fn system_double_click_interval_is_available_from_appkit() {
    let interval = system_double_click_interval().expect("AppKit double-click interval");
    assert!(!interval.is_zero());
}

#[test]
fn reset_discards_click_sequence_for_reused_session_epoch() {
    let poster = Arc::new(RecordingPoster::new([
        Ok(()),
        Ok(()),
        Ok(()),
        Ok(()),
        Ok(()),
    ]));
    let input =
        MacNativeInput::with_poster_and_click_interval(poster.clone(), Duration::from_millis(500));
    let press = PlatformNativeInputEvent::PointerButton {
        pointer_id: 0,
        button: 1,
        pressed: true,
        absolute_position: None,
    };
    let release = PlatformNativeInputEvent::PointerButton {
        pointer_id: 0,
        button: 1,
        pressed: false,
        absolute_position: None,
    };

    input.handle(22, press.clone()).unwrap();
    input.handle(22, release.clone()).unwrap();
    input.reset(22).unwrap();
    input.handle(22, press).unwrap();

    assert_eq!(
        poster.events(),
        vec![
            PostedEvent::Button {
                button: 1,
                pressed: true,
                click_state: 1,
            },
            PostedEvent::Button {
                button: 1,
                pressed: false,
                click_state: 1,
            },
            PostedEvent::Button {
                button: 1,
                pressed: true,
                click_state: 1,
            },
        ]
    );
}

#[test]
fn failed_left_release_remains_pressed_for_reset_retry() {
    let poster = Arc::new(RecordingPoster::new([
        Ok(()),
        Err("left-up failed".to_owned()),
        Err("reset attempt one failed".to_owned()),
        Ok(()),
    ]));
    let input = MacNativeInput::with_poster(poster.clone());
    let press = PlatformNativeInputEvent::PointerButton {
        pointer_id: 0,
        button: 1,
        pressed: true,
        absolute_position: None,
    };
    let release = PlatformNativeInputEvent::PointerButton {
        pointer_id: 0,
        button: 1,
        pressed: false,
        absolute_position: None,
    };

    input.handle(7, press).unwrap();
    assert_eq!(input.handle(7, release), Err("left-up failed".to_owned()));
    input.reset(7).unwrap();
    input.reset(7).unwrap();

    assert_eq!(
        poster.events(),
        vec![
            PostedEvent::Button {
                button: 1,
                pressed: true,
                click_state: 1,
            },
            PostedEvent::Button {
                button: 1,
                pressed: false,
                click_state: 1,
            },
            PostedEvent::Button {
                button: 1,
                pressed: false,
                click_state: 1,
            },
            PostedEvent::Button {
                button: 1,
                pressed: false,
                click_state: 1,
            },
        ]
    );
}

#[test]
fn repeated_key_down_preserves_the_native_autorepeat_marker() {
    let poster = Arc::new(RecordingPoster::new([Ok(()), Ok(()), Ok(())]));
    let input = MacNativeInput::with_poster(poster.clone());

    input
        .handle(
            8,
            PlatformNativeInputEvent::Keyboard {
                hid_usage: 0x04,
                pressed: true,
                modifiers: 0,
                repeat: false,
            },
        )
        .unwrap();
    input
        .handle(
            8,
            PlatformNativeInputEvent::Keyboard {
                hid_usage: 0x04,
                pressed: true,
                modifiers: 0,
                repeat: true,
            },
        )
        .unwrap();
    input
        .handle(
            8,
            PlatformNativeInputEvent::Keyboard {
                hid_usage: 0x04,
                pressed: false,
                modifiers: 0,
                repeat: false,
            },
        )
        .unwrap();

    assert_eq!(
        poster.events(),
        vec![
            PostedEvent::Key {
                hid_usage: 0x04,
                pressed: true,
                modifiers: 0,
                repeat: false,
            },
            PostedEvent::Key {
                hid_usage: 0x04,
                pressed: true,
                modifiers: 0,
                repeat: true,
            },
            PostedEvent::Key {
                hid_usage: 0x04,
                pressed: false,
                modifiers: 0,
                repeat: false,
            },
        ]
    );
}

#[test]
fn failed_key_release_remains_pressed_for_reset_retry() {
    let poster = Arc::new(RecordingPoster::new([
        Ok(()),
        Err("key-up failed".to_owned()),
        Err("reset attempt one failed".to_owned()),
        Ok(()),
    ]));
    let input = MacNativeInput::with_poster(poster.clone());
    let press = PlatformNativeInputEvent::Keyboard {
        hid_usage: 0x04,
        pressed: true,
        modifiers: 0x88,
        repeat: false,
    };
    let release = PlatformNativeInputEvent::Keyboard {
        hid_usage: 0x04,
        pressed: false,
        modifiers: 0,
        repeat: false,
    };

    input.handle(9, press).unwrap();
    assert_eq!(input.handle(9, release), Err("key-up failed".to_owned()));
    input.reset(9).unwrap();
    input.reset(9).unwrap();

    assert_eq!(
        poster.events(),
        vec![
            PostedEvent::Key {
                hid_usage: 0x04,
                pressed: true,
                modifiers: 0x88,
                repeat: false,
            },
            PostedEvent::Key {
                hid_usage: 0x04,
                pressed: false,
                modifiers: 0,
                repeat: false,
            },
            PostedEvent::Key {
                hid_usage: 0x04,
                pressed: false,
                modifiers: 0,
                repeat: false,
            },
            PostedEvent::Key {
                hid_usage: 0x04,
                pressed: false,
                modifiers: 0,
                repeat: false,
            },
        ]
    );
}

#[test]
fn failed_button_press_does_not_leave_a_pressed_ledger_entry() {
    let poster = Arc::new(RecordingPoster::new([Err("left-down failed".to_owned())]));
    let input = MacNativeInput::with_poster(poster.clone());
    let press = PlatformNativeInputEvent::PointerButton {
        pointer_id: 0,
        button: 1,
        pressed: true,
        absolute_position: None,
    };

    assert_eq!(input.handle(11, press), Err("left-down failed".to_owned()));
    input.reset(11).unwrap();

    assert_eq!(
        poster.events(),
        vec![PostedEvent::Button {
            button: 1,
            pressed: true,
            click_state: 1,
        }]
    );
}

#[test]
fn failed_reset_retains_one_retry_then_discards_the_epoch_after_final_failure() {
    let poster = Arc::new(RecordingPoster::new([
        Ok(()),
        Err("left-up failed".to_owned()),
        Err("reset attempt one failed".to_owned()),
        Err("reset attempt two failed".to_owned()),
    ]));
    let input = MacNativeInput::with_poster(poster.clone());
    let press = PlatformNativeInputEvent::PointerButton {
        pointer_id: 0,
        button: 1,
        pressed: true,
        absolute_position: None,
    };
    let release = PlatformNativeInputEvent::PointerButton {
        pointer_id: 0,
        button: 1,
        pressed: false,
        absolute_position: None,
    };

    input.handle(12, press).unwrap();
    assert!(input.handle(12, release).is_err());
    assert!(input.reset(12).is_err());
    input.reset(12).unwrap();

    assert_eq!(
        poster.events(),
        vec![
            PostedEvent::Button {
                button: 1,
                pressed: true,
                click_state: 1,
            },
            PostedEvent::Button {
                button: 1,
                pressed: false,
                click_state: 1,
            },
            PostedEvent::Button {
                button: 1,
                pressed: false,
                click_state: 1,
            },
            PostedEvent::Button {
                button: 1,
                pressed: false,
                click_state: 1,
            },
        ]
    );
}

#[test]
fn reset_retries_only_failed_items_after_partial_release() {
    let poster = Arc::new(RecordingPoster::new([
        Ok(()),
        Ok(()),
        Ok(()),
        Err("button-up failed".to_owned()),
        Ok(()),
    ]));
    let input = MacNativeInput::with_poster(poster.clone());
    let key_press = PlatformNativeInputEvent::Keyboard {
        hid_usage: 0x04,
        pressed: true,
        modifiers: 0,
        repeat: false,
    };
    let button_press = PlatformNativeInputEvent::PointerButton {
        pointer_id: 0,
        button: 1,
        pressed: true,
        absolute_position: None,
    };

    input.handle(13, key_press).unwrap();
    input.handle(13, button_press).unwrap();
    input.reset(13).unwrap();

    assert_eq!(
        poster.events(),
        vec![
            PostedEvent::Key {
                hid_usage: 0x04,
                pressed: true,
                modifiers: 0,
                repeat: false,
            },
            PostedEvent::Button {
                button: 1,
                pressed: true,
                click_state: 1,
            },
            PostedEvent::Key {
                hid_usage: 0x04,
                pressed: false,
                modifiers: 0,
                repeat: false,
            },
            PostedEvent::Button {
                button: 1,
                pressed: false,
                click_state: 1,
            },
            PostedEvent::Button {
                button: 1,
                pressed: false,
                click_state: 1,
            },
        ]
    );
}

#[test]
fn reset_all_releases_command_and_buttons_across_abrupt_session_stop() {
    let poster = Arc::new(RecordingPoster::new([
        Ok(()),
        Ok(()),
        Ok(()),
        Ok(()),
        Ok(()),
        Ok(()),
    ]));
    let input = MacNativeInput::with_poster(poster.clone());

    input
        .handle(
            31,
            PlatformNativeInputEvent::Keyboard {
                hid_usage: 0xE3,
                pressed: true,
                modifiers: 0x08,
                repeat: false,
            },
        )
        .unwrap();
    input
        .handle(
            31,
            PlatformNativeInputEvent::PointerButton {
                pointer_id: 0,
                button: 1,
                pressed: true,
                absolute_position: None,
            },
        )
        .unwrap();

    input.reset_all().unwrap();
    input.reset(31).unwrap();

    assert_eq!(
        poster.events(),
        vec![
            PostedEvent::Key {
                hid_usage: 0xE3,
                pressed: true,
                modifiers: 0x08,
                repeat: false,
            },
            PostedEvent::Button {
                button: 1,
                pressed: true,
                click_state: 1,
            },
            PostedEvent::Key {
                hid_usage: 0xE3,
                pressed: false,
                modifiers: 0,
                repeat: false,
            },
            PostedEvent::Button {
                button: 1,
                pressed: false,
                click_state: 1,
            },
        ]
    );
}

#[test]
fn stale_release_from_reset_epoch_cannot_change_new_generation_state() {
    let poster = Arc::new(RecordingPoster::new([
        Ok(()),
        Ok(()),
        Ok(()),
        Ok(()),
        Ok(()),
    ]));
    let input = MacNativeInput::with_poster(poster.clone());
    let command_down = |session_epoch| {
        input
            .handle(
                session_epoch,
                PlatformNativeInputEvent::Keyboard {
                    hid_usage: 0xE3,
                    pressed: true,
                    modifiers: 0x08,
                    repeat: false,
                },
            )
            .unwrap();
    };

    command_down(41);
    input.reset(41).unwrap();
    command_down(42);
    input
        .handle(
            41,
            PlatformNativeInputEvent::Keyboard {
                hid_usage: 0xE3,
                pressed: false,
                modifiers: 0,
                repeat: false,
            },
        )
        .unwrap();
    input.reset(42).unwrap();

    assert_eq!(
        poster.events(),
        vec![
            PostedEvent::Key {
                hid_usage: 0xE3,
                pressed: true,
                modifiers: 0x08,
                repeat: false,
            },
            PostedEvent::Key {
                hid_usage: 0xE3,
                pressed: false,
                modifiers: 0,
                repeat: false,
            },
            PostedEvent::Key {
                hid_usage: 0xE3,
                pressed: true,
                modifiers: 0x08,
                repeat: false,
            },
            PostedEvent::Key {
                hid_usage: 0xE3,
                pressed: false,
                modifiers: 0,
                repeat: false,
            },
        ]
    );
}

#[test]
fn usb_hid_mapping_preserves_physical_keys_and_multilingual_modifiers() {
    assert_eq!(mac_key_code(0x04), Some(0x00));
    assert_eq!(mac_key_code(0xe4), Some(0x3e));
    assert_eq!(mac_key_code(0x48), None);
    assert!(mac_modifier_flags(0xff).contains(CGEventFlags::CGEventFlagCommand));
}

#[test]
fn planned_virtual_bounds_map_relative_and_absolute_pointer_motion() {
    let bounds = MacInputDisplayBounds {
        width: 2340.0,
        height: 1612.0,
    }
    .rect()
    .expect("planned bounds");
    let relative = pointer_target(
        CGPoint::new(4000.0, 4000.0),
        bounds,
        NativePointerMotionMode::Relative,
        10,
        -12,
        0.0,
        0.0,
    )
    .expect("relative target");
    assert_eq!(relative.x, 1180.0);
    assert_eq!(relative.y, 794.0);
    let absolute = pointer_target(
        CGPoint::new(0.0, 0.0),
        bounds,
        NativePointerMotionMode::Absolute,
        0,
        0,
        1.0,
        1.0,
    )
    .expect("absolute target");
    assert_eq!(absolute.x, 2339.0);
    assert_eq!(absolute.y, 1611.0);
}

#[test]
fn preserved_physical_capture_viewport_remaps_absolute_pointer_position() {
    let source = CGSize::new(2560.0, 1440.0);
    let output = CGSize::new(3600.0, 2260.0);
    let left = 520.0 / 3599.0;
    let top = 410.0 / 2259.0;
    let right = 3079.0 / 3599.0;
    let bottom = 1849.0 / 2259.0;

    let top_left = remap_preserved_capture_position(left as f32, top as f32, source, output)
        .expect("top-left mapping");
    let bottom_right =
        remap_preserved_capture_position(right as f32, bottom as f32, source, output)
            .expect("bottom-right mapping");

    assert!(top_left.0.abs() < 0.000_01);
    assert!(top_left.1.abs() < 0.000_01);
    assert!((bottom_right.0 - 1.0).abs() < 0.000_01);
    assert!((bottom_right.1 - 1.0).abs() < 0.000_01);
}

#[test]
fn preserved_physical_capture_viewport_accounts_for_downscale_letterbox() {
    let source = CGSize::new(2560.0, 1440.0);
    let output = CGSize::new(1280.0, 800.0);
    let top = 40.0 / 799.0;
    let bottom = 759.0 / 799.0;

    let top_center = remap_preserved_capture_position(0.5, top as f32, source, output)
        .expect("top-center mapping");
    let bottom_center = remap_preserved_capture_position(0.5, bottom as f32, source, output)
        .expect("bottom-center mapping");

    assert!((top_center.0 - 0.5).abs() < 0.001);
    assert!(top_center.1.abs() < 0.000_01);
    assert!((bottom_center.0 - 0.5).abs() < 0.001);
    assert!((bottom_center.1 - 1.0).abs() < 0.000_01);
}

#[test]
fn published_session_bounds_take_precedence_over_planned_virtual_bounds() {
    let published = CGRect::new(&CGPoint::new(1440.0, 0.0), &CGSize::new(2560.0, 1440.0));
    let planned = MacInputDisplayBounds {
        width: 960.0,
        height: 540.0,
    };
    let selected =
        preferred_pointer_bounds(76, published, Some(planned)).expect("published session bounds");
    assert_eq!(selected.origin.x, 1440.0);
    assert_eq!(selected.size.width, 2560.0);
    assert_eq!(selected.size.height, 1440.0);
}
