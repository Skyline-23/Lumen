use std::cell::RefCell;
use std::mem::size_of;
use std::ptr::{null, null_mut};
use std::sync::mpsc;
use std::thread;
use std::time::{Duration, Instant};

use windows_sys::Win32::Foundation::{
    GetLastError, LocalFree, ERROR_CLASS_ALREADY_EXISTS, ERROR_SUCCESS, HWND, LPARAM, LRESULT,
    POINT, WPARAM,
};
use windows_sys::Win32::Security::Authorization::{
    GetSecurityInfo, SetEntriesInAclW, SetSecurityInfo, EXPLICIT_ACCESS_W, GRANT_ACCESS,
    NO_MULTIPLE_TRUSTEE, SE_KERNEL_OBJECT, TRUSTEE_IS_SID, TRUSTEE_IS_UNKNOWN, TRUSTEE_W,
};
use windows_sys::Win32::Security::{
    AllocateAndInitializeSid, FreeSid, ACL, DACL_SECURITY_INFORMATION, NO_INHERITANCE,
    PSECURITY_DESCRIPTOR, PSID, SECURITY_WORLD_SID_AUTHORITY,
};
use windows_sys::Win32::System::LibraryLoader::GetModuleHandleW;
use windows_sys::Win32::System::SystemServices::SECURITY_WORLD_RID;
use windows_sys::Win32::System::Threading::{GetCurrentThread, THREAD_SYNCHRONIZE};
use windows_sys::Win32::UI::Shell::{
    Shell_NotifyIconW, NIF_ICON, NIF_MESSAGE, NIF_TIP, NIM_ADD, NIM_DELETE, NOTIFYICONDATAW,
};
use windows_sys::Win32::UI::WindowsAndMessaging::{
    AppendMenuW, CreatePopupMenu, CreateWindowExW, DefWindowProcW, DestroyMenu, DestroyWindow,
    DispatchMessageW, GetCursorPos, GetMessageW, GetShellWindow, LoadIconW, PostMessageW,
    PostQuitMessage, RegisterClassW, RegisterWindowMessageW, SetForegroundWindow, TrackPopupMenu,
    TranslateMessage, IDI_APPLICATION, MF_SEPARATOR, MF_STRING, MSG, TPM_RETURNCMD,
    TPM_RIGHTBUTTON, WM_APP, WM_CLOSE, WM_DESTROY, WM_LBUTTONUP, WM_NULL, WM_RBUTTONUP, WNDCLASSW,
};

use crate::native_command::{
    lumen_host_send_command, LUMEN_HOST_COMMAND_FORCE_STOP_STREAM,
    LUMEN_HOST_COMMAND_RELOAD_APPLICATIONS, LUMEN_HOST_COMMAND_RESTART,
    LUMEN_HOST_COMMAND_SHUTDOWN,
};

use super::native_shell::lumen_host_show_windows_shell;

const WINDOW_CLASS: &[u16] = &[
    0x004c, 0x0075, 0x006d, 0x0065, 0x006e, 0x0052, 0x0075, 0x0073, 0x0074, 0x0054, 0x0072, 0x0061,
    0x0079, 0,
];
const WINDOW_TITLE: &[u16] = &[
    0x004c, 0x0075, 0x006d, 0x0065, 0x006e, 0x0020, 0x0054, 0x0072, 0x0061, 0x0079, 0,
];
const TASKBAR_CREATED: &[u16] = &[
    0x0054, 0x0061, 0x0073, 0x006b, 0x0062, 0x0061, 0x0072, 0x0043, 0x0072, 0x0065, 0x0061, 0x0074,
    0x0065, 0x0064, 0,
];
const TRAY_CALLBACK: u32 = WM_APP + 1;
const TRAY_ICON_ID: u32 = 1;
const RESOURCE_ICON_ID: usize = 101;
const MENU_OPEN: usize = 1;
const MENU_RELOAD: usize = 2;
const MENU_FORCE_STOP: usize = 3;
const MENU_RESTART: usize = 4;
const MENU_QUIT: usize = 5;

thread_local! {
    static TRAY_STRINGS: RefCell<Option<TrayStrings>> = const { RefCell::new(None) };
    static TASKBAR_MESSAGE: RefCell<u32> = const { RefCell::new(0) };
}

pub(crate) struct NativeWindowsTray {
    window: usize,
    thread: Option<thread::JoinHandle<()>>,
}

impl NativeWindowsTray {
    pub(crate) fn start(endpoint: String, locale: String) -> Result<Self, String> {
        let (ready_sender, ready_receiver) = mpsc::sync_channel(1);
        let thread = thread::Builder::new()
            .name("lumen-windows-tray".to_owned())
            .spawn(move || run_tray(endpoint, locale, ready_sender))
            .map_err(|error| format!("Windows tray thread failed to start: {error}"))?;
        match ready_receiver.recv() {
            Ok(Ok(window)) => Ok(Self {
                window,
                thread: Some(thread),
            }),
            Ok(Err(error)) => {
                let _ = thread.join();
                Err(error)
            }
            Err(_) => {
                let _ = thread.join();
                Err("Windows tray thread stopped before becoming ready".to_owned())
            }
        }
    }
}

impl Drop for NativeWindowsTray {
    fn drop(&mut self) {
        unsafe {
            PostMessageW(self.window as HWND, WM_CLOSE, 0, 0);
        }
        if let Some(thread) = self.thread.take() {
            if thread.join().is_err() {
                eprintln!("Lumen Windows tray thread did not stop cleanly");
            }
        }
    }
}

#[derive(Clone)]
struct TrayStrings {
    open: String,
    reload: &'static str,
    force_stop: &'static str,
    restart: &'static str,
    quit: &'static str,
}

impl TrayStrings {
    fn localized(endpoint: &str, locale: &str) -> Self {
        let normalized = locale.to_ascii_lowercase().replace('_', "-");
        let (open, reload, force_stop, restart, quit) = if normalized.starts_with("ko") {
            (
                "Lumen 열기",
                "애플리케이션 새로고침",
                "스트림 강제 종료",
                "Lumen 재시작",
                "Lumen 종료",
            )
        } else if normalized.starts_with("ja") {
            (
                "Lumenを開く",
                "アプリケーションを再読み込み",
                "ストリームを強制停止",
                "Lumenを再起動",
                "Lumenを終了",
            )
        } else if normalized.starts_with("zh-hant")
            || normalized.starts_with("zh-tw")
            || normalized.starts_with("zh-hk")
        {
            (
                "開啟 Lumen",
                "重新載入應用程式",
                "強制停止串流",
                "重新啟動 Lumen",
                "結束 Lumen",
            )
        } else if normalized.starts_with("zh") {
            (
                "打开 Lumen",
                "重新加载应用程序",
                "强制停止串流",
                "重启 Lumen",
                "退出 Lumen",
            )
        } else if normalized.starts_with("de") {
            (
                "Lumen öffnen",
                "Anwendungen neu laden",
                "Stream sofort beenden",
                "Lumen neu starten",
                "Lumen beenden",
            )
        } else if normalized.starts_with("es") {
            (
                "Abrir Lumen",
                "Recargar aplicaciones",
                "Detener transmisión",
                "Reiniciar Lumen",
                "Salir de Lumen",
            )
        } else if normalized.starts_with("fr") {
            (
                "Ouvrir Lumen",
                "Recharger les applications",
                "Arrêter le flux",
                "Redémarrer Lumen",
                "Quitter Lumen",
            )
        } else if normalized.starts_with("pt") {
            (
                "Abrir Lumen",
                "Recarregar aplicativos",
                "Interromper transmissão",
                "Reiniciar Lumen",
                "Sair do Lumen",
            )
        } else {
            (
                "Open Lumen",
                "Reload applications",
                "Force stop stream",
                "Restart Lumen",
                "Quit Lumen",
            )
        };
        Self {
            open: format!("{open} ({endpoint})"),
            reload,
            force_stop,
            restart,
            quit,
        }
    }
}

fn run_tray(endpoint: String, locale: String, ready: mpsc::SyncSender<Result<usize, String>>) {
    if !allow_shell_to_monitor_thread() {
        let _ = ready.send(Err(
            "Windows tray thread permissions could not be configured".to_owned(),
        ));
        return;
    }
    let deadline = Instant::now() + Duration::from_secs(10);
    while unsafe { GetShellWindow() }.is_null() {
        if Instant::now() >= deadline {
            let _ = ready.send(Err("Windows shell did not become available".to_owned()));
            return;
        }
        thread::sleep(Duration::from_millis(100));
    }

    TRAY_STRINGS.with(|storage| {
        *storage.borrow_mut() = Some(TrayStrings::localized(&endpoint, &locale));
    });
    TASKBAR_MESSAGE.with(|message| {
        *message.borrow_mut() = unsafe { RegisterWindowMessageW(TASKBAR_CREATED.as_ptr()) };
    });

    let instance = unsafe { GetModuleHandleW(null()) };
    let icon = load_tray_icon(instance);
    let window_class = WNDCLASSW {
        lpfnWndProc: Some(window_proc),
        hInstance: instance,
        hIcon: icon,
        lpszClassName: WINDOW_CLASS.as_ptr(),
        ..Default::default()
    };
    let atom = unsafe { RegisterClassW(&window_class) };
    if atom == 0 && unsafe { GetLastError() } != ERROR_CLASS_ALREADY_EXISTS {
        let _ = ready.send(Err(format!(
            "Windows tray class registration failed: {}",
            unsafe { GetLastError() }
        )));
        return;
    }
    let window = unsafe {
        CreateWindowExW(
            0,
            WINDOW_CLASS.as_ptr(),
            WINDOW_TITLE.as_ptr(),
            0,
            0,
            0,
            0,
            0,
            null_mut(),
            null_mut(),
            instance,
            null(),
        )
    };
    if window.is_null() {
        let _ = ready.send(Err(format!(
            "Windows tray window creation failed: {}",
            unsafe { GetLastError() }
        )));
        return;
    }
    if !add_tray_icon(window) {
        let error = unsafe { GetLastError() };
        unsafe { DestroyWindow(window) };
        let _ = ready.send(Err(format!("Windows tray icon creation failed: {}", error)));
        return;
    }
    let _ = ready.send(Ok(window as usize));

    let mut message = MSG::default();
    while unsafe { GetMessageW(&mut message, null_mut(), 0, 0) } > 0 {
        unsafe {
            TranslateMessage(&message);
            DispatchMessageW(&message);
        }
    }
    TRAY_STRINGS.with(|storage| storage.borrow_mut().take());
}

unsafe extern "system" fn window_proc(
    window: HWND,
    message: u32,
    w_param: WPARAM,
    l_param: LPARAM,
) -> LRESULT {
    let taskbar_message = TASKBAR_MESSAGE.with(|value| *value.borrow());
    if taskbar_message != 0 && message == taskbar_message {
        add_tray_icon(window);
        return 0;
    }
    match message {
        TRAY_CALLBACK => {
            if l_param as u32 == WM_LBUTTONUP || l_param as u32 == WM_RBUTTONUP {
                show_menu(window);
            }
            0
        }
        WM_CLOSE => {
            remove_tray_icon(window);
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

fn show_menu(window: HWND) {
    TRAY_STRINGS.with(|storage| {
        let storage = storage.borrow();
        let Some(strings) = storage.as_ref() else {
            return;
        };
        let menu = unsafe { CreatePopupMenu() };
        if menu.is_null() {
            return;
        }
        let appended = append_menu(menu, MENU_OPEN, &strings.open)
            && unsafe { AppendMenuW(menu, MF_SEPARATOR, 0, null()) } != 0
            && append_menu(menu, MENU_RELOAD, strings.reload)
            && append_menu(menu, MENU_FORCE_STOP, strings.force_stop)
            && append_menu(menu, MENU_RESTART, strings.restart)
            && append_menu(menu, MENU_QUIT, strings.quit);
        if !appended {
            unsafe { DestroyMenu(menu) };
            return;
        }
        let mut point = POINT::default();
        if unsafe { GetCursorPos(&mut point) } == 0 {
            unsafe { DestroyMenu(menu) };
            return;
        }
        unsafe { SetForegroundWindow(window) };
        let command = unsafe {
            TrackPopupMenu(
                menu,
                TPM_RIGHTBUTTON | TPM_RETURNCMD,
                point.x,
                point.y,
                0,
                window,
                null(),
            )
        } as usize;
        unsafe {
            PostMessageW(window, WM_NULL, 0, 0);
            DestroyMenu(menu);
        }
        dispatch_menu(command);
    });
}

fn append_menu(menu: *mut core::ffi::c_void, command: usize, title: &str) -> bool {
    let title = wide(title);
    unsafe { AppendMenuW(menu, MF_STRING, command, title.as_ptr()) != 0 }
}

fn dispatch_menu(command: usize) {
    match command {
        MENU_OPEN => lumen_host_show_windows_shell(),
        MENU_RELOAD => {
            let _ = lumen_host_send_command(LUMEN_HOST_COMMAND_RELOAD_APPLICATIONS);
        }
        MENU_FORCE_STOP => {
            let _ = lumen_host_send_command(LUMEN_HOST_COMMAND_FORCE_STOP_STREAM);
        }
        MENU_RESTART => {
            let _ = lumen_host_send_command(LUMEN_HOST_COMMAND_RESTART);
        }
        MENU_QUIT => {
            let _ = lumen_host_send_command(LUMEN_HOST_COMMAND_SHUTDOWN);
        }
        _ => {}
    }
}

fn tray_icon_data(window: HWND) -> NOTIFYICONDATAW {
    let mut data = NOTIFYICONDATAW {
        cbSize: size_of::<NOTIFYICONDATAW>() as u32,
        hWnd: window,
        uID: TRAY_ICON_ID,
        uFlags: NIF_ICON | NIF_MESSAGE | NIF_TIP,
        uCallbackMessage: TRAY_CALLBACK,
        hIcon: load_tray_icon(unsafe { GetModuleHandleW(null()) }),
        ..Default::default()
    };
    let tooltip = "Lumen".encode_utf16().collect::<Vec<_>>();
    data.szTip[..tooltip.len()].copy_from_slice(&tooltip);
    data
}

fn add_tray_icon(window: HWND) -> bool {
    let data = tray_icon_data(window);
    unsafe { Shell_NotifyIconW(NIM_ADD, &data) != 0 }
}

fn remove_tray_icon(window: HWND) {
    let data = tray_icon_data(window);
    unsafe {
        Shell_NotifyIconW(NIM_DELETE, &data);
    }
}

fn load_tray_icon(instance: *mut core::ffi::c_void) -> *mut core::ffi::c_void {
    let icon = unsafe { LoadIconW(instance, RESOURCE_ICON_ID as *const u16) };
    if icon.is_null() {
        unsafe { LoadIconW(null_mut(), IDI_APPLICATION) }
    } else {
        icon
    }
}

fn wide(value: &str) -> Vec<u16> {
    value.encode_utf16().chain(std::iter::once(0)).collect()
}

fn allow_shell_to_monitor_thread() -> bool {
    let mut old_acl: *mut ACL = null_mut();
    let mut descriptor: PSECURITY_DESCRIPTOR = null_mut();
    let status = unsafe {
        GetSecurityInfo(
            GetCurrentThread(),
            SE_KERNEL_OBJECT,
            DACL_SECURITY_INFORMATION,
            null_mut(),
            null_mut(),
            &mut old_acl,
            null_mut(),
            &mut descriptor,
        )
    };
    if status != ERROR_SUCCESS {
        return false;
    }

    let mut world: PSID = null_mut();
    let allocated = unsafe {
        AllocateAndInitializeSid(
            &SECURITY_WORLD_SID_AUTHORITY,
            1,
            SECURITY_WORLD_RID as u32,
            0,
            0,
            0,
            0,
            0,
            0,
            0,
            &mut world,
        )
    } != 0;
    if !allocated {
        unsafe { LocalFree(descriptor) };
        return false;
    }

    let access = EXPLICIT_ACCESS_W {
        grfAccessPermissions: THREAD_SYNCHRONIZE,
        grfAccessMode: GRANT_ACCESS,
        grfInheritance: NO_INHERITANCE,
        Trustee: TRUSTEE_W {
            pMultipleTrustee: null_mut(),
            MultipleTrusteeOperation: NO_MULTIPLE_TRUSTEE,
            TrusteeForm: TRUSTEE_IS_SID,
            TrusteeType: TRUSTEE_IS_UNKNOWN,
            ptstrName: world.cast(),
        },
    };
    let mut new_acl: *mut ACL = null_mut();
    let mut status = unsafe { SetEntriesInAclW(1, &access, old_acl, &mut new_acl) };
    if status == ERROR_SUCCESS {
        status = unsafe {
            SetSecurityInfo(
                GetCurrentThread(),
                SE_KERNEL_OBJECT,
                DACL_SECURITY_INFORMATION,
                null_mut(),
                null_mut(),
                new_acl,
                null_mut(),
            )
        };
    }
    unsafe {
        if !new_acl.is_null() {
            LocalFree(new_acl.cast());
        }
        FreeSid(world);
        LocalFree(descriptor);
    }
    status == ERROR_SUCCESS
}
