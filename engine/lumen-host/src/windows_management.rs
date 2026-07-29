use serde::{Deserialize, Serialize};

use crate::windows_app::{WindowsAppModel, WindowsBooleanSetting, WindowsOwnerAccessState};

#[derive(Debug, Deserialize)]
#[serde(tag = "command", rename_all = "camelCase")]
enum WindowsManagementRequest {
    Snapshot,
    CreateOwner {
        username: String,
        password: String,
        confirmation: String,
    },
    Login {
        password: String,
    },
    Logout,
    UpdateBoolean {
        setting: i32,
        enabled: bool,
    },
    ReloadApplications,
    ForceStopStream,
    RestartHost,
    ShutdownHost,
}

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
struct WindowsManagementResponse<T: Serialize> {
    ok: bool,
    payload: Option<T>,
    error: Option<WindowsManagementError>,
}

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
struct WindowsManagementError {
    code: &'static str,
    message: String,
}

pub(crate) trait WindowsManagementCommands {
    fn reload_applications(&self) -> Result<(), String>;
    fn force_stop_stream(&self) -> Result<(), String>;
    fn restart_host(&self) -> Result<(), String>;
    fn shutdown_host(&self) -> Result<(), String>;
}

pub(crate) fn handle_windows_management_request(
    model: &mut WindowsAppModel,
    commands: &dyn WindowsManagementCommands,
    request: &[u8],
) -> Vec<u8> {
    let response = match serde_json::from_slice::<WindowsManagementRequest>(request) {
        Ok(request) => dispatch(model, commands, request),
        Err(error) => error_response("invalidRequest", format!("invalid request: {error}")),
    };
    serde_json::to_vec(&response).unwrap_or_else(|error| {
        format!(
            "{{\"ok\":false,\"payload\":null,\"error\":{{\"code\":\"serializationFailed\",\"message\":{}}}}}",
            serde_json::to_string(&error.to_string()).unwrap_or_else(|_| "\"serialization failed\"".to_owned())
        )
        .into_bytes()
    })
}

fn dispatch(
    model: &mut WindowsAppModel,
    commands: &dyn WindowsManagementCommands,
    request: WindowsManagementRequest,
) -> WindowsManagementResponse<serde_json::Value> {
    if let Err(response) = authorize_request(model, &request) {
        return response;
    }
    let result = match request {
        WindowsManagementRequest::Snapshot => Ok(()),
        WindowsManagementRequest::CreateOwner {
            username,
            password,
            confirmation,
        } => model
            .create_owner(&username, &password, &confirmation)
            .map_err(|error| format!("owner setup failed: {error:?}")),
        WindowsManagementRequest::Login { password } => model
            .login(&password)
            .map_err(|error| format!("login failed: {error:?}")),
        WindowsManagementRequest::Logout => {
            model.lock();
            Ok(())
        }
        WindowsManagementRequest::UpdateBoolean { setting, enabled } => {
            let setting = WindowsBooleanSetting::from_index(setting)
                .ok_or_else(|| "unknown boolean setting".to_owned());
            setting.and_then(|setting| model.update_boolean_setting(setting, enabled))
        }
        WindowsManagementRequest::ReloadApplications => commands.reload_applications(),
        WindowsManagementRequest::ForceStopStream => commands.force_stop_stream(),
        WindowsManagementRequest::RestartHost => commands.restart_host(),
        WindowsManagementRequest::ShutdownHost => commands.shutdown_host(),
    };
    if let Err(message) = result {
        return error_response("commandFailed", message);
    }
    match model.management_snapshot() {
        Ok(snapshot) => match serde_json::to_value(snapshot) {
            Ok(payload) => WindowsManagementResponse {
                ok: true,
                payload: Some(payload),
                error: None,
            },
            Err(error) => error_response("serializationFailed", error.to_string()),
        },
        Err(message) => error_response("snapshotFailed", message),
    }
}

fn authorize_request(
    model: &WindowsAppModel,
    request: &WindowsManagementRequest,
) -> Result<(), WindowsManagementResponse<serde_json::Value>> {
    let owner_access = model.owner_access_state();
    let allowed = match request {
        // The native app needs one read-only bootstrap response to choose the
        // setup or login UI. It cannot mutate host state.
        WindowsManagementRequest::Snapshot => true,
        // Owner creation is the single setup mutation allowed before an owner
        // exists. The owner store still validates the supplied credentials.
        WindowsManagementRequest::CreateOwner { .. } => {
            matches!(owner_access, WindowsOwnerAccessState::SetupRequired)
        }
        // Password verification is the only path from a locked owner store to
        // an authenticated management session.
        WindowsManagementRequest::Login { .. } => {
            matches!(owner_access, WindowsOwnerAccessState::LoginRequired(_))
        }
        WindowsManagementRequest::Logout
        | WindowsManagementRequest::UpdateBoolean { .. }
        | WindowsManagementRequest::ReloadApplications
        | WindowsManagementRequest::ForceStopStream
        | WindowsManagementRequest::RestartHost
        | WindowsManagementRequest::ShutdownHost => {
            matches!(owner_access, WindowsOwnerAccessState::Authenticated(_))
        }
    };
    allowed.then_some(()).ok_or_else(|| {
        error_response(
            "authenticationRequired",
            "authenticated owner access is required for this management request".to_owned(),
        )
    })
}

fn error_response(
    code: &'static str,
    message: String,
) -> WindowsManagementResponse<serde_json::Value> {
    WindowsManagementResponse {
        ok: false,
        payload: None,
        error: Some(WindowsManagementError { code, message }),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::windows_app::WindowsAppModel;
    use lumen_engine::settings::SettingsAuthority;
    use std::path::Path;

    use std::sync::atomic::{AtomicUsize, Ordering};

    #[derive(Default)]
    struct Commands {
        reloads: AtomicUsize,
        stops: AtomicUsize,
        restarts: AtomicUsize,
        shutdowns: AtomicUsize,
    }

    impl WindowsManagementCommands for Commands {
        fn reload_applications(&self) -> Result<(), String> {
            self.reloads.fetch_add(1, Ordering::Relaxed);
            Ok(())
        }
        fn force_stop_stream(&self) -> Result<(), String> {
            self.stops.fetch_add(1, Ordering::Relaxed);
            Ok(())
        }
        fn restart_host(&self) -> Result<(), String> {
            self.restarts.fetch_add(1, Ordering::Relaxed);
            Ok(())
        }
        fn shutdown_host(&self) -> Result<(), String> {
            self.shutdowns.fetch_add(1, Ordering::Relaxed);
            Ok(())
        }
    }

    fn model(root: &Path) -> WindowsAppModel {
        let settings_path = root.join("settings.json");
        SettingsAuthority::open(
            settings_path.clone(),
            lumen_engine::settings::SettingsCapabilities::for_platform(
                lumen_engine::settings::SettingsHostPlatform::Windows,
            ),
        )
        .unwrap();
        WindowsAppModel::for_test(root)
    }

    #[test]
    fn snapshot_is_versioned_and_serialized_for_the_native_client() {
        let root = tempfile::tempdir().unwrap();
        let mut model = model(root.path());
        let commands = Commands::default();
        let response =
            handle_windows_management_request(&mut model, &commands, br#"{"command":"snapshot"}"#);
        let value: serde_json::Value = serde_json::from_slice(&response).unwrap();
        assert_eq!(value["ok"], true);
        assert_eq!(value["payload"]["protocolVersion"], 1);
        assert_eq!(value["payload"]["ownerState"], "setupRequired");
        assert_eq!(value["payload"]["hostName"], "Studio");
    }

    #[test]
    fn malformed_and_unknown_setting_requests_fail_closed() {
        let root = tempfile::tempdir().unwrap();
        let mut model = model(root.path());
        let commands = Commands::default();
        let malformed = handle_windows_management_request(&mut model, &commands, b"not-json");
        let malformed: serde_json::Value = serde_json::from_slice(&malformed).unwrap();
        assert_eq!(malformed["error"]["code"], "invalidRequest");

        authenticate(&mut model, &commands);
        let unknown = handle_windows_management_request(
            &mut model,
            &commands,
            br#"{"command":"updateBoolean","setting":99,"enabled":true}"#,
        );
        let unknown: serde_json::Value = serde_json::from_slice(&unknown).unwrap();
        assert_eq!(unknown["error"]["code"], "commandFailed");
    }

    #[test]
    fn dispatcher_allows_only_bootstrap_authentication_before_owner_login() {
        let root = tempfile::tempdir().unwrap();
        let mut model = model(root.path());
        let commands = Commands::default();

        let snapshot = request(&mut model, &commands, br#"{"command":"snapshot"}"#);
        assert_eq!(snapshot["ok"], true);
        for denied in [
            br#"{"command":"logout"}"#.as_slice(),
            br#"{"command":"updateBoolean","setting":0,"enabled":false}"#.as_slice(),
            br#"{"command":"reloadApplications"}"#.as_slice(),
            br#"{"command":"forceStopStream"}"#.as_slice(),
            br#"{"command":"restartHost"}"#.as_slice(),
            br#"{"command":"shutdownHost"}"#.as_slice(),
        ] {
            let response = request(&mut model, &commands, denied);
            assert_eq!(response["error"]["code"], "authenticationRequired");
        }
        assert!(model.snapshot().unwrap().settings.general.discovery);
        assert_eq!(commands.reloads.load(Ordering::Relaxed), 0);
        assert_eq!(commands.stops.load(Ordering::Relaxed), 0);
        assert_eq!(commands.restarts.load(Ordering::Relaxed), 0);
        assert_eq!(commands.shutdowns.load(Ordering::Relaxed), 0);

        let invalid_login = request(
            &mut model,
            &commands,
            br#"{"command":"login","password":"correct horse battery staple"}"#,
        );
        assert_eq!(invalid_login["error"]["code"], "authenticationRequired");
    }

    #[test]
    fn authenticated_owner_can_mutate_and_logout_revokes_every_privileged_command() {
        let root = tempfile::tempdir().unwrap();
        let mut model = model(root.path());
        let commands = Commands::default();
        authenticate(&mut model, &commands);

        for allowed in [
            br#"{"command":"updateBoolean","setting":0,"enabled":false}"#.as_slice(),
            br#"{"command":"reloadApplications"}"#.as_slice(),
            br#"{"command":"forceStopStream"}"#.as_slice(),
            br#"{"command":"restartHost"}"#.as_slice(),
            br#"{"command":"shutdownHost"}"#.as_slice(),
        ] {
            assert_eq!(request(&mut model, &commands, allowed)["ok"], true);
        }
        assert!(!model.snapshot().unwrap().settings.general.discovery);
        assert_eq!(commands.reloads.load(Ordering::Relaxed), 1);
        assert_eq!(commands.stops.load(Ordering::Relaxed), 1);
        assert_eq!(commands.restarts.load(Ordering::Relaxed), 1);
        assert_eq!(commands.shutdowns.load(Ordering::Relaxed), 1);

        assert_eq!(
            request(&mut model, &commands, br#"{"command":"logout"}"#)["ok"],
            true
        );
        let denied = request(&mut model, &commands, br#"{"command":"shutdownHost"}"#);
        assert_eq!(denied["error"]["code"], "authenticationRequired");
        assert_eq!(commands.shutdowns.load(Ordering::Relaxed), 1);
    }

    fn authenticate(model: &mut WindowsAppModel, commands: &Commands) {
        let response = request(
            model,
            commands,
            br#"{"command":"createOwner","username":"owner","password":"correct horse battery staple","confirmation":"correct horse battery staple"}"#,
        );
        assert_eq!(response["ok"], true);
        assert_eq!(response["payload"]["ownerState"], "authenticated");
    }

    fn request(
        model: &mut WindowsAppModel,
        commands: &Commands,
        bytes: &[u8],
    ) -> serde_json::Value {
        serde_json::from_slice(&handle_windows_management_request(model, commands, bytes)).unwrap()
    }
}
