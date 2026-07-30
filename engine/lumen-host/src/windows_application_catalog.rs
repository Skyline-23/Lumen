use std::path::Path;

use lumen_engine::ApplicationCatalog;

use crate::{HostArguments, HostAuthorityPaths};

#[cfg(windows)]
pub(crate) fn prepare(arguments: &HostArguments) -> Result<(), String> {
    let executable = std::env::current_exe().map_err(|error| {
        format!("Windows application catalog executable is unavailable: {error}")
    })?;
    prepare_from_executable(arguments, &executable)
}

fn prepare_from_executable(arguments: &HostArguments, executable: &Path) -> Result<(), String> {
    let install_root = executable
        .parent()
        .filter(|path| !path.as_os_str().is_empty())
        .ok_or_else(|| {
            format!(
                "Windows application catalog install root is invalid: {}",
                executable.display()
            )
        })?;
    let seed_path = install_root.join("assets").join("apps.json");
    let runtime_path = HostAuthorityPaths::from_arguments(arguments)
        .map_err(|error| error.to_string())?
        .applications;
    ApplicationCatalog::open_seeded(runtime_path, seed_path)
        .map(|_| ())
        .map_err(|error| format!("Windows application catalog preparation failed: {error:?}"))
}

#[cfg(test)]
mod tests {
    use std::fs;
    use std::path::PathBuf;

    use super::*;

    fn arguments_with_catalog(path: PathBuf) -> HostArguments {
        let root = path.parent().unwrap();
        let mut values = crate::config::tests::valid_arguments();
        for value in &mut values {
            let replacement = if value.starts_with("file_apps=") {
                Some(path.clone())
            } else if value.starts_with("credentials_file=") {
                Some(root.join("credentials.json"))
            } else if value.starts_with("file_state=") {
                Some(root.join("state.json"))
            } else {
                None
            };
            if let Some(replacement) = replacement {
                let key = value.split_once('=').unwrap().0;
                *value = format!("{key}={}", replacement.display());
            }
        }
        HostArguments::parse(values).unwrap()
    }

    #[test]
    fn upgrades_an_installed_empty_catalog_from_the_shipped_windows_seed() {
        let root = tempfile::tempdir().unwrap();
        let install_root = root.path().join("Lumen");
        let runtime_path = install_root.join("config").join("apps.json");
        let seed_path = install_root.join("assets").join("apps.json");
        fs::create_dir_all(runtime_path.parent().unwrap()).unwrap();
        fs::create_dir_all(seed_path.parent().unwrap()).unwrap();
        fs::write(
            &runtime_path,
            r#"{"env":{"UPGRADE":"preserved"},"apps":[]}"#,
        )
        .unwrap();
        fs::write(
            &seed_path,
            include_bytes!("../../../src_assets/windows/assets/apps.json"),
        )
        .unwrap();
        let arguments = arguments_with_catalog(runtime_path.clone());

        prepare_from_executable(&arguments, &install_root.join("LumenSessionAgent.exe")).unwrap();

        let catalog = ApplicationCatalog::open(runtime_path.clone()).unwrap();
        assert_eq!(
            catalog
                .applications()
                .unwrap()
                .into_iter()
                .map(|application| application.name)
                .collect::<Vec<_>>(),
            ["Desktop"]
        );
        let document: serde_json::Value =
            serde_json::from_slice(&fs::read(runtime_path).unwrap()).unwrap();
        assert_eq!(document["env"]["UPGRADE"], "preserved");
    }

    #[test]
    fn shipped_windows_seed_contains_the_required_desktop_entry() {
        let document: serde_json::Value =
            serde_json::from_str(include_str!("../../../src_assets/windows/assets/apps.json"))
                .unwrap();
        assert_eq!(document["apps"].as_array().unwrap().len(), 1);
        assert_eq!(document["apps"][0]["name"], "Desktop");
    }

    #[test]
    fn missing_shipped_seed_fails_without_replacing_the_runtime_catalog() {
        let root = tempfile::tempdir().unwrap();
        let install_root = root.path().join("Lumen");
        let runtime_path = install_root.join("config").join("apps.json");
        fs::create_dir_all(runtime_path.parent().unwrap()).unwrap();
        let original = br#"{"env":{},"apps":[]}"#;
        fs::write(&runtime_path, original).unwrap();
        let arguments = arguments_with_catalog(runtime_path.clone());

        let error =
            prepare_from_executable(&arguments, &install_root.join("LumenSessionAgent.exe"))
                .unwrap_err();

        assert!(error.contains("Storage"));
        assert_eq!(fs::read(runtime_path).unwrap(), original);
    }
}
