use std::fmt::Write as _;
use std::fs;
use std::io::Write as _;
use std::path::{Path, PathBuf};

use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};

use crate::{
    RecoveryJournalError, RecoveryJournalLoad, RecoveryWarningCode, WorkspaceRecoveryJournal,
    WorkspaceRecoveryWarning, WORKSPACE_RECOVERY_SCHEMA_VERSION,
};

#[derive(Debug)]
pub struct RecoveryJournalStore {
    path: PathBuf,
}

#[derive(Deserialize, Serialize)]
struct RecoveryJournalEnvelope {
    schema_version: u32,
    checksum_sha256: String,
    journal: WorkspaceRecoveryJournal,
}

impl RecoveryJournalStore {
    pub fn new(path: PathBuf) -> Self {
        Self { path }
    }

    pub fn path(&self) -> &Path {
        &self.path
    }

    pub fn create(&self, journal: &WorkspaceRecoveryJournal) -> Result<(), RecoveryJournalError> {
        if self.path.exists() {
            return Err(RecoveryJournalError::AlreadyExists);
        }
        journal.validate()?;
        self.write_atomically(journal)
    }

    pub fn update(&self, journal: &WorkspaceRecoveryJournal) -> Result<(), RecoveryJournalError> {
        let current = match self.load()? {
            RecoveryJournalLoad::Missing => return Err(RecoveryJournalError::Missing),
            RecoveryJournalLoad::Verified(current) => current,
            RecoveryJournalLoad::Quarantined(_) => {
                return Err(RecoveryJournalError::InvalidField("journal"));
            }
        };
        if current.generation != journal.generation {
            return Err(RecoveryJournalError::StaleGeneration {
                expected: current.generation,
                actual: journal.generation,
            });
        }
        if current.session_id != journal.session_id {
            return Err(RecoveryJournalError::SessionMismatch);
        }
        journal.validate()?;
        self.write_atomically(journal)
    }

    pub fn load(&self) -> Result<RecoveryJournalLoad, RecoveryJournalError> {
        let bytes = match fs::read(&self.path) {
            Ok(bytes) => bytes,
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => {
                return Ok(RecoveryJournalLoad::Missing);
            }
            Err(_) => return Err(RecoveryJournalError::Storage("read")),
        };
        let envelope: RecoveryJournalEnvelope = match serde_json::from_slice(&bytes) {
            Ok(envelope) => envelope,
            Err(_) => return self.quarantine(&bytes, RecoveryWarningCode::MalformedJournal),
        };
        if envelope.schema_version != WORKSPACE_RECOVERY_SCHEMA_VERSION {
            return self.quarantine(&bytes, RecoveryWarningCode::UnsupportedVersion);
        }
        if envelope.journal.validate().is_err() {
            return self.quarantine(&bytes, RecoveryWarningCode::InvalidJournal);
        }
        let payload = serde_json::to_vec(&envelope.journal)
            .map_err(|_| RecoveryJournalError::Serialization)?;
        if envelope.checksum_sha256 != checksum_hex(&payload) {
            return self.quarantine(&bytes, RecoveryWarningCode::ChecksumMismatch);
        }
        Ok(RecoveryJournalLoad::Verified(envelope.journal))
    }

    pub fn delete(&self) -> Result<(), RecoveryJournalError> {
        fs::remove_file(&self.path).map_err(|error| {
            if error.kind() == std::io::ErrorKind::NotFound {
                RecoveryJournalError::Missing
            } else {
                RecoveryJournalError::Storage("delete")
            }
        })
    }

    fn write_atomically(
        &self,
        journal: &WorkspaceRecoveryJournal,
    ) -> Result<(), RecoveryJournalError> {
        let parent = self
            .path
            .parent()
            .filter(|parent| !parent.as_os_str().is_empty())
            .ok_or(RecoveryJournalError::Storage("resolve-parent"))?;
        fs::create_dir_all(parent)
            .map_err(|_| RecoveryJournalError::Storage("create-directory"))?;
        let payload =
            serde_json::to_vec(journal).map_err(|_| RecoveryJournalError::Serialization)?;
        let envelope = RecoveryJournalEnvelope {
            schema_version: WORKSPACE_RECOVERY_SCHEMA_VERSION,
            checksum_sha256: checksum_hex(&payload),
            journal: journal.clone(),
        };
        let serialized = serde_json::to_vec_pretty(&envelope)
            .map_err(|_| RecoveryJournalError::Serialization)?;
        let mut temporary = tempfile::Builder::new()
            .prefix(".lumen-display-recovery-")
            .tempfile_in(parent)
            .map_err(|_| RecoveryJournalError::Storage("create-temporary"))?;
        temporary
            .write_all(&serialized)
            .and_then(|_| temporary.flush())
            .and_then(|_| temporary.as_file().sync_all())
            .map_err(|_| RecoveryJournalError::Storage("write-temporary"))?;
        temporary
            .persist(&self.path)
            .map_err(|_| RecoveryJournalError::Storage("atomic-replace"))?;
        sync_parent(parent)?;
        Ok(())
    }

    fn quarantine(
        &self,
        bytes: &[u8],
        code: RecoveryWarningCode,
    ) -> Result<RecoveryJournalLoad, RecoveryJournalError> {
        let digest = checksum_hex(bytes);
        let quarantine_suffix = digest
            .get(..16)
            .ok_or(RecoveryJournalError::Serialization)?;
        let file_name = self
            .path
            .file_name()
            .and_then(|name| name.to_str())
            .ok_or(RecoveryJournalError::Storage("resolve-quarantine"))?;
        let quarantined_path = self
            .path
            .with_file_name(format!("{file_name}.quarantine-{quarantine_suffix}"));
        match fs::rename(&self.path, &quarantined_path) {
            Ok(()) => {}
            Err(error) if error.kind() == std::io::ErrorKind::AlreadyExists => {
                fs::remove_file(&self.path)
                    .map_err(|_| RecoveryJournalError::Storage("deduplicate-quarantine"))?;
            }
            Err(_) => return Err(RecoveryJournalError::Storage("quarantine")),
        }
        Ok(RecoveryJournalLoad::Quarantined(WorkspaceRecoveryWarning {
            code,
            quarantined_path,
        }))
    }
}

fn checksum_hex(bytes: &[u8]) -> String {
    let digest = Sha256::digest(bytes);
    let mut encoded = String::with_capacity(digest.len() * 2);
    for byte in digest {
        let _ = write!(encoded, "{byte:02x}");
    }
    encoded
}

#[cfg(unix)]
fn sync_parent(parent: &Path) -> Result<(), RecoveryJournalError> {
    fs::File::open(parent)
        .and_then(|directory| directory.sync_all())
        .map_err(|_| RecoveryJournalError::Storage("sync-directory"))
}

#[cfg(not(unix))]
fn sync_parent(_parent: &Path) -> Result<(), RecoveryJournalError> {
    Ok(())
}
