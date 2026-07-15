use std::sync::mpsc;
use std::thread;
use std::time::Duration;

use windows_sys::Win32::Foundation::{
    GetLastError, ERROR_CLASS_ALREADY_EXISTS, HWND, LPARAM, LRESULT, WPARAM,
};
use windows_sys::Win32::System::LibraryLoader::GetModuleHandleW;
use windows_sys::Win32::System::Threading::SetProcessShutdownParameters;
use windows_sys::Win32::System::WindowsProgramming::SHUTDOWN_NORETRY;
use windows_sys::Win32::UI::WindowsAndMessaging::{
    CreateWindowExW, DefWindowProcW, DestroyWindow, DispatchMessageW, GetMessageW, PostMessageW,
    PostQuitMessage, RegisterClassW, TranslateMessage, MSG, WM_CLOSE, WM_DESTROY, WM_ENDSESSION,
    WM_QUERYENDSESSION, WNDCLASSW,
};

use crate::native_command::{lumen_host_send_command, LUMEN_HOST_COMMAND_SHUTDOWN};

const WINDOW_CLASS: &[u16] = &[
    0x004c, 0x0075, 0x006d, 0x0065, 0x006e, 0x0052, 0x0075, 0x0073, 0x0074, 0x0048, 0x006f, 0x0073,
    0x0074, 0x0053, 0x0065, 0x0073, 0x0073, 0x0069, 0x006f, 0x006e, 0x004d, 0x006f, 0x006e, 0x0069,
    0x0074, 0x006f, 0x0072, 0,
];
const WINDOW_TITLE: &[u16] = &[
    0x004c, 0x0075, 0x006d, 0x0065, 0x006e, 0x0020, 0x0053, 0x0065, 0x0073, 0x0073, 0x0069, 0x006f,
    0x006e, 0x0020, 0x004d, 0x006f, 0x006e, 0x0069, 0x0074, 0x006f, 0x0072, 0,
];

pub(crate) struct NativeWindowsLifecycle {
    window: usize,
    thread: Option<thread::JoinHandle<()>>,
}

impl NativeWindowsLifecycle {
    pub(crate) fn start() -> Result<Self, String> {
        unsafe {
            SetProcessShutdownParameters(0x100, SHUTDOWN_NORETRY);
        }
        let (ready_sender, ready_receiver) = mpsc::sync_channel(1);
        let thread = thread::Builder::new()
            .name("lumen-windows-lifecycle".to_owned())
            .spawn(move || run_message_window(ready_sender))
            .map_err(|error| format!("Windows lifecycle thread failed to start: {error}"))?;
        let window = match ready_receiver.recv_timeout(Duration::from_secs(2)) {
            Ok(window) if window != 0 => window,
            _ => {
                let _ = thread.join();
                return Err("Windows lifecycle monitor failed to start".to_owned());
            }
        };
        Ok(Self {
            window,
            thread: Some(thread),
        })
    }
}

impl Drop for NativeWindowsLifecycle {
    fn drop(&mut self) {
        unsafe {
            PostMessageW(self.window as HWND, WM_CLOSE, 0, 0);
        }
        if let Some(thread) = self.thread.take() {
            let _ = thread.join();
        }
    }
}

fn run_message_window(ready: mpsc::SyncSender<usize>) {
    let instance = unsafe { GetModuleHandleW(std::ptr::null()) };
    let window_class = WNDCLASSW {
        lpfnWndProc: Some(window_proc),
        hInstance: instance,
        lpszClassName: WINDOW_CLASS.as_ptr(),
        ..Default::default()
    };
    let atom = unsafe { RegisterClassW(&window_class) };
    let registered = atom != 0 || unsafe { GetLastError() } == ERROR_CLASS_ALREADY_EXISTS;
    let window = if registered {
        unsafe {
            CreateWindowExW(
                0,
                WINDOW_CLASS.as_ptr(),
                WINDOW_TITLE.as_ptr(),
                0,
                0,
                0,
                0,
                0,
                std::ptr::null_mut(),
                std::ptr::null_mut(),
                instance,
                std::ptr::null(),
            )
        }
    } else {
        std::ptr::null_mut()
    };
    let _ = ready.send(window as usize);
    if window.is_null() {
        return;
    }
    let mut message = MSG::default();
    while unsafe { GetMessageW(&mut message, std::ptr::null_mut(), 0, 0) } > 0 {
        unsafe {
            TranslateMessage(&message);
            DispatchMessageW(&message);
        }
    }
}

unsafe extern "system" fn window_proc(
    window: HWND,
    message: u32,
    w_param: WPARAM,
    l_param: LPARAM,
) -> LRESULT {
    match message {
        WM_QUERYENDSESSION => 1,
        WM_ENDSESSION => {
            if w_param != 0 {
                let _ = lumen_host_send_command(LUMEN_HOST_COMMAND_SHUTDOWN);
            }
            0
        }
        WM_CLOSE => {
            unsafe { DestroyWindow(window) };
            0
        }
        WM_DESTROY => {
            unsafe { PostQuitMessage(0) };
            0
        }
        _ => unsafe { DefWindowProcW(window, message, w_param, l_param) },
    }
}
