use core_graphics::display::CGDisplay;
use core_graphics::event::{CGEvent, CGEventTapLocation, CGEventType, CGMouseButton, EventField};
use core_graphics::geometry::{CGPoint, CGRect, CGSize};
use lumen_engine::NativePointerMotionMode;

use super::{MacInputCaptureViewport, MacInputDisplayBounds, MacInputState};

#[derive(Clone, Copy, Debug)]
pub(super) struct MacPointerMotionInput {
    pub(super) mode: NativePointerMotionMode,
    pub(super) delta_x: i32,
    pub(super) delta_y: i32,
    pub(super) normalized_x: f32,
    pub(super) normalized_y: f32,
}

pub(super) fn post_pointer_motion(
    display_id: u32,
    planned_bounds: Option<MacInputDisplayBounds>,
    capture_viewport: Option<MacInputCaptureViewport>,
    state: &MacInputState,
    input: MacPointerMotionInput,
) -> Result<CGPoint, String> {
    let source = super::event_source()?;
    let current = CGEvent::new(source.clone())
        .map_err(|_| "could not inspect the macOS pointer location".to_owned())?
        .location();
    let bounds = preferred_pointer_bounds(
        display_id,
        CGDisplay::new(display_id).bounds(),
        planned_bounds,
    )?;
    let input = if input.mode == NativePointerMotionMode::Absolute {
        capture_viewport
            .and_then(|viewport| {
                let display = CGDisplay::new(display_id);
                remap_preserved_capture_position(
                    input.normalized_x,
                    input.normalized_y,
                    CGSize::new(display.pixels_wide() as f64, display.pixels_high() as f64),
                    CGSize::new(viewport.width, viewport.height),
                )
            })
            .map_or(input, |(normalized_x, normalized_y)| {
                MacPointerMotionInput {
                    normalized_x,
                    normalized_y,
                    ..input
                }
            })
    } else {
        input
    };
    let target = pointer_target(
        current,
        bounds,
        input.mode,
        input.delta_x,
        input.delta_y,
        input.normalized_x,
        input.normalized_y,
    )?;
    let (event_type, button) = drag_event(state);
    let event = CGEvent::new_mouse_event(source, event_type, target, button)
        .map_err(|_| "could not create macOS pointer motion event".to_owned())?;
    event.set_integer_value_field(EventField::MOUSE_EVENT_DELTA_X, i64::from(input.delta_x));
    event.set_integer_value_field(EventField::MOUSE_EVENT_DELTA_Y, i64::from(input.delta_y));
    event.post(CGEventTapLocation::HID);
    Ok(target)
}

pub(super) fn remap_preserved_capture_position(
    normalized_x: f32,
    normalized_y: f32,
    source_size: CGSize,
    output_size: CGSize,
) -> Option<(f32, f32)> {
    if source_size.width <= 0.0
        || source_size.height <= 0.0
        || output_size.width <= 1.0
        || output_size.height <= 1.0
    {
        return None;
    }

    // Lumen configures ScreenCaptureKit with preservesAspectRatio=true and
    // scalesToFit=false. The source can scale down, but it is never enlarged.
    let scale = 1.0_f64
        .min(output_size.width / source_size.width)
        .min(output_size.height / source_size.height);
    let content_width = source_size.width * scale;
    let content_height = source_size.height * scale;
    let origin_x = (output_size.width - content_width) * 0.5;
    let origin_y = (output_size.height - content_height) * 0.5;
    let output_x = f64::from(normalized_x) * (output_size.width - 1.0);
    let output_y = f64::from(normalized_y) * (output_size.height - 1.0);
    let mapped_x = ((output_x - origin_x) / (content_width - 1.0)).clamp(0.0, 1.0);
    let mapped_y = ((output_y - origin_y) / (content_height - 1.0)).clamp(0.0, 1.0);
    Some((mapped_x as f32, mapped_y as f32))
}

pub(super) fn preferred_pointer_bounds(
    display_id: u32,
    published_bounds: CGRect,
    planned_bounds: Option<MacInputDisplayBounds>,
) -> Result<CGRect, String> {
    // Input targets the active session display. Its published bounds must win over the planned
    // virtual geometry whenever CoreGraphics has them available.
    if published_bounds.size.width > 0.0 && published_bounds.size.height > 0.0 {
        return Ok(published_bounds);
    }
    planned_bounds
        .and_then(MacInputDisplayBounds::rect)
        .ok_or_else(|| {
            format!("macOS native motion display {display_id} has no published or planned bounds")
        })
}

pub(super) fn pointer_target(
    current: CGPoint,
    bounds: CGRect,
    mode: NativePointerMotionMode,
    delta_x: i32,
    delta_y: i32,
    normalized_x: f32,
    normalized_y: f32,
) -> Result<CGPoint, String> {
    match mode {
        NativePointerMotionMode::Relative => {
            let origin = if point_in_rect(current, bounds) {
                current
            } else {
                CGPoint::new(
                    bounds.origin.x + bounds.size.width / 2.0,
                    bounds.origin.y + bounds.size.height / 2.0,
                )
            };
            Ok(CGPoint::new(
                (origin.x + f64::from(delta_x))
                    .clamp(bounds.origin.x, bounds.origin.x + bounds.size.width - 1.0),
                (origin.y + f64::from(delta_y))
                    .clamp(bounds.origin.y, bounds.origin.y + bounds.size.height - 1.0),
            ))
        }
        NativePointerMotionMode::Absolute => Ok(CGPoint::new(
            bounds.origin.x + f64::from(normalized_x) * (bounds.size.width - 1.0),
            bounds.origin.y + f64::from(normalized_y) * (bounds.size.height - 1.0),
        )),
        NativePointerMotionMode::Unspecified => {
            Err("macOS native pointer motion mode is unspecified".to_owned())
        }
    }
}

fn point_in_rect(point: CGPoint, bounds: CGRect) -> bool {
    point.x >= bounds.origin.x
        && point.x < bounds.origin.x + bounds.size.width
        && point.y >= bounds.origin.y
        && point.y < bounds.origin.y + bounds.size.height
}

fn drag_event(state: &MacInputState) -> (CGEventType, CGMouseButton) {
    if state.pressed_buttons.contains(&1) {
        (CGEventType::LeftMouseDragged, CGMouseButton::Left)
    } else if state.pressed_buttons.contains(&3) {
        (CGEventType::RightMouseDragged, CGMouseButton::Right)
    } else if state
        .pressed_buttons
        .iter()
        .any(|button| (2..=5).contains(button))
    {
        (CGEventType::OtherMouseDragged, CGMouseButton::Center)
    } else {
        (CGEventType::MouseMoved, CGMouseButton::Left)
    }
}
