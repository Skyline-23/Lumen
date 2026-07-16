use lumen_engine::settings::{SettingsCapabilities, SettingsHostPlatform};

pub(super) fn native_settings_capabilities() -> SettingsCapabilities {
    #[cfg(target_os = "macos")]
    let platform = SettingsHostPlatform::Macos;
    #[cfg(windows)]
    let platform = SettingsHostPlatform::Windows;
    SettingsCapabilities::for_platform(platform)
}
