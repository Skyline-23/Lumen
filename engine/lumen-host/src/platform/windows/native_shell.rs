use std::cell::RefCell;
use std::rc::Rc;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::mpsc;
use std::thread;
use std::time::Duration;

use slint::{ComponentHandle, ModelRc, SharedString, Timer, TimerMode, VecModel};

use crate::native_command::{
    lumen_host_send_command, LUMEN_HOST_COMMAND_FORCE_STOP_STREAM,
    LUMEN_HOST_COMMAND_RELOAD_APPLICATIONS, LUMEN_HOST_COMMAND_RESTART,
    LUMEN_HOST_COMMAND_SHUTDOWN,
};
use crate::windows_app::{
    WindowsAppModel, WindowsAppSnapshot, WindowsNavigation, WindowsOwnerAccessState,
};
use crate::HostArguments;

use super::native_tray::NativeWindowsTray;

slint::include_modules!();

static SHOW_REQUESTED: AtomicBool = AtomicBool::new(false);
static QUIT_REQUESTED: AtomicBool = AtomicBool::new(false);

enum WindowsUiError {
    Owner(lumen_engine::OwnerAccountError),
}

impl WindowsUiError {
    fn code(&self) -> i32 {
        use lumen_engine::OwnerAccountError;
        match self {
            Self::Owner(OwnerAccountError::InvalidArgument) => 0,
            Self::Owner(OwnerAccountError::AlreadyExists) => 1,
            Self::Owner(OwnerAccountError::AuthenticationFailed) => 2,
            Self::Owner(OwnerAccountError::Storage) => 3,
            Self::Owner(OwnerAccountError::Corrupt) => 4,
        }
    }

    fn detail(&self) -> &str {
        ""
    }
}

pub(crate) struct NativeWindowsShell {
    tray: Option<NativeWindowsTray>,
    ui_thread: Option<thread::JoinHandle<()>>,
}

impl NativeWindowsShell {
    pub(crate) fn start(arguments: &HostArguments) -> Result<Self, String> {
        let model = WindowsAppModel::from_arguments(arguments)?;
        let initial = model.snapshot()?;
        let tray_endpoint = format!("{}:{}", initial.host_name, initial.control_port);
        SHOW_REQUESTED.store(false, Ordering::Release);
        QUIT_REQUESTED.store(false, Ordering::Release);
        let (ready_sender, ready_receiver) = mpsc::sync_channel(1);
        let ui_thread = thread::Builder::new()
            .name("lumen-windows-ui".to_owned())
            .spawn(move || run_ui(model, initial, ready_sender))
            .map_err(|error| format!("Windows UI thread failed to start: {error}"))?;
        ready_receiver
            .recv_timeout(Duration::from_secs(10))
            .map_err(|_| "Windows UI did not become ready".to_owned())??;

        let tray = NativeWindowsTray::start(tray_endpoint)
            .map_err(|error| eprintln!("Lumen Windows tray is unavailable: {error}"))
            .ok();
        Ok(Self {
            tray,
            ui_thread: Some(ui_thread),
        })
    }
}

impl Drop for NativeWindowsShell {
    fn drop(&mut self) {
        drop(self.tray.take());
        QUIT_REQUESTED.store(true, Ordering::Release);
        if let Some(thread) = self.ui_thread.take() {
            if thread.join().is_err() {
                eprintln!("Lumen Windows UI thread did not stop cleanly");
            }
        }
    }
}

#[no_mangle]
pub extern "C" fn lumen_host_show_windows_shell() {
    SHOW_REQUESTED.store(true, Ordering::Release);
}

fn run_ui(
    model: WindowsAppModel,
    initial: WindowsAppSnapshot,
    ready: mpsc::SyncSender<Result<(), String>>,
) {
    let ui = match LumenWindowsApp::new() {
        Ok(ui) => ui,
        Err(error) => {
            let _ = ready.send(Err(format!("Windows UI could not be created: {error}")));
            return;
        }
    };
    let model = Rc::new(RefCell::new(model));
    apply_snapshot(&ui, &initial, None);
    wire_callbacks(&ui, Rc::clone(&model));

    let close_window = ui.as_weak();
    ui.window().on_close_requested(move || {
        if let Some(ui) = close_window.upgrade() {
            let _ = ui.hide();
        }
        slint::CloseRequestResponse::KeepWindowShown
    });

    let event_window = ui.as_weak();
    let timer = Timer::default();
    timer.start(TimerMode::Repeated, Duration::from_millis(80), move || {
        let Some(ui) = event_window.upgrade() else {
            return;
        };
        if SHOW_REQUESTED.swap(false, Ordering::AcqRel) {
            let _ = ui.show();
        }
        if QUIT_REQUESTED.swap(false, Ordering::AcqRel) {
            let _ = slint::quit_event_loop();
        }
    });

    if let Err(error) = ui.show() {
        let _ = ready.send(Err(format!("Windows UI could not be shown: {error}")));
        return;
    }
    let _ = ready.send(Ok(()));
    if let Err(error) = slint::run_event_loop_until_quit() {
        eprintln!("Lumen Windows UI event loop failed: {error}");
    }
    drop(timer);
}

fn wire_callbacks(ui: &LumenWindowsApp, model: Rc<RefCell<WindowsAppModel>>) {
    let weak = ui.as_weak();
    let create_model = Rc::clone(&model);
    ui.on_create_owner(move |username, password, confirmation| {
        let result = create_model.borrow_mut().create_owner(
            username.as_str(),
            password.as_str(),
            confirmation.as_str(),
        );
        refresh(
            &weak,
            &create_model,
            result.err().map(WindowsUiError::Owner),
        );
    });

    let weak = ui.as_weak();
    let login_model = Rc::clone(&model);
    ui.on_login(move |password| {
        let result = login_model.borrow_mut().login(password.as_str());
        refresh(&weak, &login_model, result.err().map(WindowsUiError::Owner));
    });

    let weak = ui.as_weak();
    let lock_model = Rc::clone(&model);
    ui.on_lock(move || {
        lock_model.borrow_mut().lock();
        refresh(&weak, &lock_model, None);
    });

    let weak = ui.as_weak();
    let navigation_model = Rc::clone(&model);
    ui.on_navigate(move |index| {
        navigation_model
            .borrow_mut()
            .select(WindowsNavigation::from_index(index));
        refresh(&weak, &navigation_model, None);
    });

    let weak = ui.as_weak();
    let reload_model = Rc::clone(&model);
    ui.on_reload_applications(move || {
        let _ = lumen_host_send_command(LUMEN_HOST_COMMAND_RELOAD_APPLICATIONS);
        refresh(&weak, &reload_model, None);
    });
    ui.on_force_stop_stream(move || {
        let _ = lumen_host_send_command(LUMEN_HOST_COMMAND_FORCE_STOP_STREAM);
    });
    ui.on_restart_host(move || {
        let _ = lumen_host_send_command(LUMEN_HOST_COMMAND_RESTART);
    });
    ui.on_quit_host(move || {
        let _ = lumen_host_send_command(LUMEN_HOST_COMMAND_SHUTDOWN);
    });
}

fn refresh(
    ui: &slint::Weak<LumenWindowsApp>,
    model: &Rc<RefCell<WindowsAppModel>>,
    error: Option<WindowsUiError>,
) {
    let Some(ui) = ui.upgrade() else {
        return;
    };
    match model.borrow().snapshot() {
        Ok(snapshot) => apply_snapshot(&ui, &snapshot, error.as_ref()),
        Err(message) => {
            ui.set_auth_error_code(-1);
            ui.set_auth_error_detail(message.into());
        }
    }
}

fn apply_snapshot(
    ui: &LumenWindowsApp,
    snapshot: &WindowsAppSnapshot,
    error: Option<&WindowsUiError>,
) {
    let (auth_mode, owner_name) = match &snapshot.owner_access {
        WindowsOwnerAccessState::SetupRequired => (0, ""),
        WindowsOwnerAccessState::LoginRequired(username)
        | WindowsOwnerAccessState::Authenticated(username) => {
            let mode = i32::from(matches!(
                snapshot.owner_access,
                WindowsOwnerAccessState::Authenticated(_)
            )) + 1;
            (mode, username.as_str())
        }
        WindowsOwnerAccessState::Corrupt => (1, ""),
        WindowsOwnerAccessState::Unavailable => (1, ""),
    };
    ui.set_auth_mode(auth_mode);
    ui.set_owner_name(owner_name.into());
    ui.set_auth_error_code(error.map_or(-1, WindowsUiError::code));
    ui.set_auth_error_detail(error.map_or("", WindowsUiError::detail).into());
    ui.set_navigation(snapshot.navigation.index());
    ui.set_host_name(snapshot.host_name.as_str().into());
    ui.set_application_count(snapshot.applications.len() as i32);
    ui.set_application_names(ModelRc::new(VecModel::from(
        snapshot
            .applications
            .iter()
            .map(|application| SharedString::from(application.title.as_str()))
            .collect::<Vec<_>>(),
    )));
    ui.set_control_port(i32::from(snapshot.control_port));
}
