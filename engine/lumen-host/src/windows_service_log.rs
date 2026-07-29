use std::fs::OpenOptions;
use std::io::Write;
use std::path::PathBuf;
use std::time::{SystemTime, UNIX_EPOCH};

use serde::Serialize;

#[cfg(windows)]
const SERVICE_EVENT_LOG_FILE: &str = "service-events.jsonl";

#[derive(Clone, Copy, Debug, Eq, PartialEq, Serialize)]
pub(crate) struct WindowsAdaptiveVideoApplyEvent {
    event: &'static str,
    timestamp_unix_ms: u128,
    pub(crate) session_epoch: u32,
    pub(crate) encoder_epoch: u64,
    pub(crate) requested_bitrate_bps: u32,
    pub(crate) applied_bitrate_bps: u32,
}

impl WindowsAdaptiveVideoApplyEvent {
    pub(crate) fn now(
        session_epoch: u32,
        encoder_epoch: u64,
        requested_bitrate_bps: u32,
        applied_bitrate_bps: u32,
    ) -> Result<Self, String> {
        let timestamp_unix_ms = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .map_err(|_| "Windows service event clock predates the Unix epoch".to_owned())?
            .as_millis();
        Ok(Self {
            event: "windows_adaptive_video_apply",
            timestamp_unix_ms,
            session_epoch,
            encoder_epoch,
            requested_bitrate_bps,
            applied_bitrate_bps,
        })
    }
}

pub(crate) trait WindowsServiceEventSink: Send + Sync {
    fn record_adaptive_video_apply(
        &self,
        event: &WindowsAdaptiveVideoApplyEvent,
    ) -> Result<(), String>;
}

pub(crate) struct WindowsServiceEventLog {
    path: PathBuf,
}

impl WindowsServiceEventLog {
    #[cfg(windows)]
    pub(crate) fn from_program_data() -> Result<Self, String> {
        let path = program_data_lumen_path(SERVICE_EVENT_LOG_FILE)
            .ok_or_else(|| "Windows ProgramData is unavailable for service events".to_owned())?;
        Self::new(path)
    }

    fn new(path: PathBuf) -> Result<Self, String> {
        let directory = path
            .parent()
            .ok_or_else(|| "Windows service event log has no parent directory".to_owned())?;
        std::fs::create_dir_all(directory)
            .map_err(|error| format!("create Windows service event log directory: {error}"))?;
        Ok(Self { path })
    }

    fn append_json_line(&self, line: &[u8]) -> Result<(), String> {
        let mut file = OpenOptions::new()
            .create(true)
            .append(true)
            .open(&self.path)
            .map_err(|error| format!("open Windows service event log: {error}"))?;
        file.write_all(line)
            .and_then(|()| file.write_all(b"\n"))
            .map_err(|error| format!("append Windows service event log: {error}"))?;
        file.sync_data()
            .map_err(|error| format!("persist Windows service event log: {error}"))
    }
}

impl WindowsServiceEventSink for WindowsServiceEventLog {
    fn record_adaptive_video_apply(
        &self,
        event: &WindowsAdaptiveVideoApplyEvent,
    ) -> Result<(), String> {
        let line = serde_json::to_vec(event)
            .map_err(|error| format!("serialize Windows adaptive video event: {error}"))?;
        self.append_json_line(&line)
    }
}

#[cfg(windows)]
pub(crate) fn program_data_lumen_path(file_name: &str) -> Option<PathBuf> {
    std::env::var_os("ProgramData").map(|program_data| {
        std::path::Path::new(&program_data)
            .join("Lumen")
            .join(file_name)
    })
}

#[cfg(test)]
mod tests {
    use super::{WindowsAdaptiveVideoApplyEvent, WindowsServiceEventLog, WindowsServiceEventSink};

    #[test]
    fn adaptive_apply_reaches_a_durable_jsonl_service_sink() {
        let directory = tempfile::tempdir().unwrap();
        let path = directory.path().join("service-events.jsonl");
        let log = WindowsServiceEventLog::new(path.clone()).unwrap();
        let event = WindowsAdaptiveVideoApplyEvent::now(17, 29, 72_000_000, 72_000_000).unwrap();

        log.record_adaptive_video_apply(&event).unwrap();

        let body = std::fs::read_to_string(path).unwrap();
        let lines = body.lines().collect::<Vec<_>>();
        assert_eq!(lines.len(), 1);
        let persisted: serde_json::Value = serde_json::from_str(lines[0]).unwrap();
        assert_eq!(persisted["event"], "windows_adaptive_video_apply");
        assert_eq!(persisted["session_epoch"], 17);
        assert_eq!(persisted["encoder_epoch"], 29);
        assert_eq!(persisted["requested_bitrate_bps"], 72_000_000);
        assert_eq!(persisted["applied_bitrate_bps"], 72_000_000);
        let keys = persisted.as_object().unwrap().keys().collect::<Vec<_>>();
        assert!(!keys.iter().any(|key| {
            let key = key.to_ascii_lowercase();
            key.contains("address") || key.contains("client") || key.contains("secret")
        }));
    }
}
