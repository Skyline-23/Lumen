use serde_json::{Map, Value};
use std::fs;
use std::io::Write;
use std::path::PathBuf;

use crate::application::random_uuid;

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum HostIdentityError {
    InvalidArgument,
    Storage,
    Corrupt,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct HostIdentityAuthority {
    file_path: PathBuf,
    unique_id: String,
    authority_host: Option<String>,
}

impl HostIdentityAuthority {
    pub fn open(file_path: PathBuf) -> Result<Self, HostIdentityError> {
        if file_path.as_os_str().is_empty() || file_path.file_name().is_none() {
            return Err(HostIdentityError::InvalidArgument);
        }
        let mut document = match fs::read(&file_path) {
            Ok(data) => {
                serde_json::from_slice::<Value>(&data).map_err(|_| HostIdentityError::Corrupt)?
            }
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => Value::Object(Map::new()),
            Err(_) => return Err(HostIdentityError::Storage),
        };
        let root = document
            .as_object_mut()
            .ok_or(HostIdentityError::Corrupt)?
            .entry("root")
            .or_insert_with(|| Value::Object(Map::new()))
            .as_object_mut()
            .ok_or(HostIdentityError::Corrupt)?;
        let existing_unique_id = root
            .get("uniqueid")
            .and_then(Value::as_str)
            .map(str::trim)
            .filter(|value| !value.is_empty())
            .map(str::to_owned);
        let (unique_id, changed) = match existing_unique_id {
            Some(value) => (value, false),
            None => {
                let value = random_uuid();
                root.insert("uniqueid".to_owned(), Value::String(value.clone()));
                (value, true)
            }
        };
        let authority_host = root
            .get("authority_host")
            .and_then(Value::as_str)
            .map(str::trim)
            .filter(|value| !value.is_empty())
            .map(str::to_owned);
        if changed {
            write_document(&file_path, &document)?;
        }
        Ok(Self {
            file_path,
            unique_id,
            authority_host,
        })
    }

    pub fn file_path(&self) -> &std::path::Path {
        &self.file_path
    }

    pub fn unique_id(&self) -> &str {
        &self.unique_id
    }

    pub fn authority_host(&self) -> Option<&str> {
        self.authority_host.as_deref()
    }
}

fn write_document(file_path: &std::path::Path, document: &Value) -> Result<(), HostIdentityError> {
    let parent = file_path
        .parent()
        .filter(|path| !path.as_os_str().is_empty())
        .ok_or(HostIdentityError::InvalidArgument)?;
    fs::create_dir_all(parent).map_err(|_| HostIdentityError::Storage)?;
    let serialized = serde_json::to_vec_pretty(document).map_err(|_| HostIdentityError::Storage)?;
    let mut temporary_file = tempfile::Builder::new()
        .prefix(".host-identity.")
        .tempfile_in(parent)
        .map_err(|_| HostIdentityError::Storage)?;
    temporary_file
        .write_all(&serialized)
        .and_then(|_| temporary_file.as_file().sync_all())
        .map_err(|_| HostIdentityError::Storage)?;
    temporary_file
        .persist(file_path)
        .map_err(|_| HostIdentityError::Storage)?;
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn preserves_existing_state_and_generates_only_missing_identity() {
        let root = tempfile::tempdir().unwrap();
        let path = root.path().join("lumen-state.json");
        fs::write(
            &path,
            br#"{"password":"keep","root":{"uniqueid":"HOST-42","authority_host":"lumen.example"}}"#,
        )
        .unwrap();
        let identity = HostIdentityAuthority::open(path.clone()).unwrap();
        assert_eq!(identity.unique_id(), "HOST-42");
        assert_eq!(identity.authority_host(), Some("lumen.example"));
        let document: Value = serde_json::from_slice(&fs::read(path).unwrap()).unwrap();
        assert_eq!(document["password"], "keep");

        let generated_path = root.path().join("generated.json");
        let generated = HostIdentityAuthority::open(generated_path.clone()).unwrap();
        assert!(!generated.unique_id().is_empty());
        let reopened = HostIdentityAuthority::open(generated_path).unwrap();
        assert_eq!(reopened.unique_id(), generated.unique_id());
    }
}
