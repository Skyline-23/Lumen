use serde::{Deserialize, Serialize};

use crate::windows_app::{WindowsAppModel, WindowsBooleanSetting};

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

    struct Commands;

    impl WindowsManagementCommands for Commands {
        fn reload_applications(&self) -> Result<(), String> {
            Ok(())
        }
        fn force_stop_stream(&self) -> Result<(), String> {
            Ok(())
        }
        fn restart_host(&self) -> Result<(), String> {
            Ok(())
        }
        fn shutdown_host(&self) -> Result<(), String> {
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
        let response =
            handle_windows_management_request(&mut model, &Commands, br#"{"command":"snapshot"}"#);
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
        let malformed = handle_windows_management_request(&mut model, &Commands, b"not-json");
        let malformed: serde_json::Value = serde_json::from_slice(&malformed).unwrap();
        assert_eq!(malformed["error"]["code"], "invalidRequest");

        let unknown = handle_windows_management_request(
            &mut model,
            &Commands,
            br#"{"command":"updateBoolean","setting":99,"enabled":true}"#,
        );
        let unknown: serde_json::Value = serde_json::from_slice(&unknown).unwrap();
        assert_eq!(unknown["error"]["code"], "commandFailed");
    }
}
