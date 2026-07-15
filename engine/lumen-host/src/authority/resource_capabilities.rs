use lumen_engine::settings::{SettingsCapabilities, SettingsHostPlatform};

use crate::HostArguments;

pub(super) fn native_settings_capabilities() -> SettingsCapabilities {
    #[cfg(target_os = "macos")]
    let platform = SettingsHostPlatform::Macos;
    #[cfg(windows)]
    let platform = SettingsHostPlatform::Windows;
    SettingsCapabilities::for_platform(platform)
}

pub(super) fn advertise_native_resource_values(
    capabilities: &mut SettingsCapabilities,
    arguments: &HostArguments,
) {
    for (field, argument, default_value, default_label) in [
        (
            "streaming.adapterSelector",
            "adapter_name",
            "automatic",
            "Automatic",
        ),
        (
            "streaming.outputSelector",
            "output_name",
            "automatic",
            "Automatic",
        ),
        (
            "audio.sink",
            "audio_sink",
            "system-default",
            "System Default",
        ),
    ] {
        let mut values = vec![(default_value, default_label)];
        if let Some(configured) = arguments.get(argument) {
            values.push((configured, configured));
        }
        capabilities.set_allowed_values_with_labels(field, &values);
    }
    advertise_display_modes(capabilities, arguments);
}

fn advertise_display_modes(capabilities: &mut SettingsCapabilities, arguments: &HostArguments) {
    let Some(mode) = arguments.get("fallback_mode") else {
        return;
    };
    let mut values = capabilities.fields["streaming.fallbackDisplayMode"]
        .allowed_values
        .iter()
        .map(|value| (value.clone(), display_mode_label(value)))
        .collect::<Vec<_>>();
    if !values.iter().any(|(value, _)| value == mode) {
        values.push((mode.to_owned(), display_mode_label(mode)));
    }
    let borrowed = values
        .iter()
        .map(|(value, label)| (value.as_str(), label.as_str()))
        .collect::<Vec<_>>();
    capabilities.set_allowed_values_with_labels("streaming.fallbackDisplayMode", &borrowed);
}

fn display_mode_label(value: &str) -> String {
    let mut parts = value.split('x');
    match (parts.next(), parts.next(), parts.next(), parts.next()) {
        (Some(width), Some(height), Some(refresh), None) => {
            format!("{width} × {height} at {refresh} Hz")
        }
        _ => value.to_owned(),
    }
}
