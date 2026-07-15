#[cfg(windows)]
mod input_policy;
mod input_state;
mod media_queue;
mod process_command_line;

#[cfg(windows)]
mod native_audio;
#[cfg(windows)]
mod native_capture;
#[cfg(windows)]
mod native_desktop_input;
#[cfg(windows)]
mod native_display;
#[cfg(windows)]
mod native_input;
#[cfg(windows)]
mod native_lifecycle;
#[cfg(windows)]
mod native_media;
#[cfg(windows)]
mod native_pointer_input;
#[cfg(windows)]
mod native_process;
#[cfg(windows)]
mod native_shell;
#[cfg(windows)]
mod native_tray;
#[cfg(windows)]
mod native_video;
#[cfg(windows)]
mod native_vigem;
#[cfg(windows)]
mod native_wasapi;

#[cfg(windows)]
pub(crate) use native_input::WindowsPlatformSessionControl;
#[cfg(windows)]
pub(crate) use native_lifecycle::NativeWindowsLifecycle;
#[cfg(windows)]
pub(crate) use native_shell::NativeWindowsShell;

#[cfg(test)]
mod tests;
