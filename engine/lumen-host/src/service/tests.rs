use std::fs;
use std::sync::{Arc, Mutex};

use super::*;
use crate::{ControlMethod, ControlRequest, HostRuntime};

#[derive(Default)]
struct RecordingStreamControl {
    events: Vec<&'static str>,
}

#[derive(Default)]
struct FailingStreamControl;

impl NativeStreamControl for FailingStreamControl {
    fn start(
        &mut self,
        _arguments: &HostArguments,
        _router: Arc<Mutex<ControlRouter>>,
        _platform: Arc<dyn PlatformSessionControl>,
    ) -> Result<(), String> {
        Err("stream bind failed".to_owned())
    }

    fn force_stop(&mut self) -> Result<(), String> {
        Ok(())
    }

    fn stop(&mut self) -> Result<(), String> {
        Ok(())
    }
}

impl NativeStreamControl for RecordingStreamControl {
    fn start(
        &mut self,
        _arguments: &HostArguments,
        router: Arc<Mutex<ControlRouter>>,
        _platform: Arc<dyn PlatformSessionControl>,
    ) -> Result<(), String> {
        assert_eq!(
            router
                .lock()
                .unwrap()
                .authorities()
                .settings()
                .snapshot()
                .schema_version,
            1
        );
        self.events.push("start");
        Ok(())
    }

    fn force_stop(&mut self) -> Result<(), String> {
        self.events.push("force-stop");
        Ok(())
    }

    fn stop(&mut self) -> Result<(), String> {
        self.events.push("stop");
        Ok(())
    }
}

#[derive(Default)]
struct RecordingControlTransport {
    events: Vec<&'static str>,
}

impl NativeControlTransport for RecordingControlTransport {
    fn start(
        &mut self,
        _arguments: &HostArguments,
        router: Arc<Mutex<ControlRouter>>,
    ) -> Result<(), String> {
        assert_eq!(
            router
                .lock()
                .unwrap()
                .authorities()
                .settings()
                .snapshot()
                .schema_version,
            1
        );
        self.events.push("start");
        Ok(())
    }

    fn stop(&mut self) -> Result<(), String> {
        self.events.push("stop");
        Ok(())
    }
}

fn arguments(root: &std::path::Path, enrollment_enabled: bool) -> HostArguments {
    let mut values = crate::config::tests::valid_arguments();
    for value in &mut values {
        let replacement = if value.starts_with("credentials_file=") {
            Some(format!(
                "credentials_file={}",
                root.join("lumen_state.json").display()
            ))
        } else if value.starts_with("file_apps=") {
            Some(format!("file_apps={}", root.join("apps.json").display()))
        } else if value.starts_with("device_enrollment_enabled=") {
            Some(format!("device_enrollment_enabled={enrollment_enabled}"))
        } else if value.starts_with("enable_discovery=") {
            Some("enable_discovery=false".to_owned())
        } else {
            None
        };
        if let Some(replacement) = replacement {
            *value = replacement;
        }
    }
    HostArguments::parse(values).unwrap()
}

#[test]
fn composes_authorities_and_routes_under_one_service_lifetime() {
    let root = tempfile::tempdir().unwrap();
    let arguments = arguments(root.path(), true);
    let mut runtime = HostRuntime::new(NativeHostService::with_transports(
        RecordingStreamControl::default(),
        RecordingControlTransport::default(),
    ));
    runtime.start(&arguments).unwrap();

    {
        let router = runtime.service().router().unwrap();
        assert_eq!(
            router.authorities().paths().settings,
            root.path().join("settings.json")
        );
    }
    assert!(root.path().join("apps.json").exists());

    runtime.handle(crate::HostCommand::ForceStopStream).unwrap();
    runtime.handle(crate::HostCommand::Shutdown).unwrap();
    assert_eq!(
        runtime.service().stream_control().events,
        ["start", "force-stop", "stop"]
    );
    assert_eq!(
        runtime.service().control_transport().events,
        ["start", "stop"]
    );
    assert!(runtime.service().router().is_none());
}

#[test]
fn applies_local_enrollment_policy_and_reloads_the_catalog() {
    let root = tempfile::tempdir().unwrap();
    let arguments = arguments(root.path(), false);
    let mut service = NativeHostService::default();
    service.start(&arguments).unwrap();

    let mut enrollment =
        ControlRequest::new(ControlMethod::Post, "/api/v1/auth/enrollment-challenge");
    enrollment
        .headers
        .push(("Content-Type".into(), "application/json".into()));
    enrollment.body =
        br#"{"schemaVersion":1,"requestId":"disabled-1","request":{"publicKey":"invalid"}}"#
            .to_vec();
    let response = service.router_mut().unwrap().dispatch(&enrollment);
    assert_eq!(response.status_code, 403);

    fs::write(
        root.path().join("apps.json"),
        r#"{"apps":[{"name":"Desktop","uuid":"desktop"}]}"#,
    )
    .unwrap();
    service.reload_applications().unwrap();
    let catalog = service
        .router()
        .unwrap()
        .authorities()
        .applications()
        .json()
        .unwrap();
    assert!(String::from_utf8(catalog).unwrap().contains("Desktop"));
}

#[test]
fn rejects_duplicate_or_out_of_lifetime_operations() {
    let root = tempfile::tempdir().unwrap();
    let arguments = arguments(root.path(), true);
    let mut service = NativeHostService::default();
    assert_eq!(
        service.reload_applications(),
        Err("native host service is not running".to_owned())
    );
    service.start(&arguments).unwrap();
    assert_eq!(
        service.start(&arguments),
        Err("native host service is already running".to_owned())
    );
    service.stop().unwrap();
    assert_eq!(
        service.force_stop_stream(),
        Err("native host service is not running".to_owned())
    );
}

#[test]
fn rolls_back_the_control_listener_when_stream_startup_fails() {
    let root = tempfile::tempdir().unwrap();
    let arguments = arguments(root.path(), true);
    let mut service = NativeHostService::with_transports(
        FailingStreamControl,
        RecordingControlTransport::default(),
    );
    assert_eq!(
        service.start(&arguments),
        Err("native host stream failed: stream bind failed".to_owned())
    );
    assert_eq!(service.control_transport().events, ["start", "stop"]);
    assert!(service.router().is_none());
}
