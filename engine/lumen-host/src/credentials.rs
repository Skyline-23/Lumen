use std::fs;
use std::path::{Path, PathBuf};

use rcgen::generate_simple_self_signed;

use crate::HostArguments;

pub(crate) fn ensure_server_identity(arguments: &HostArguments) -> Result<(), String> {
    let private_key = required_path(arguments, "pkey")?;
    let certificate = required_path(arguments, "cert")?;
    if private_key.is_file() && certificate.is_file() {
        return Ok(());
    }
    create_parent(&private_key)?;
    create_parent(&certificate)?;
    let identity = generate_simple_self_signed(vec!["Lumen Host".to_owned()])
        .map_err(|error| format!("could not generate TLS identity: {error}"))?;
    write_private_key(
        &private_key,
        identity.signing_key.serialize_pem().as_bytes(),
    )?;
    if let Err(error) = atomic_write(&certificate, identity.cert.pem().as_bytes()) {
        let _ = fs::remove_file(&private_key);
        return Err(error);
    }
    Ok(())
}

fn required_path(arguments: &HostArguments, key: &str) -> Result<PathBuf, String> {
    arguments
        .get(key)
        .filter(|value| !value.is_empty())
        .map(PathBuf::from)
        .ok_or_else(|| format!("TLS identity path is missing: {key}"))
}

fn create_parent(path: &Path) -> Result<(), String> {
    let parent = path
        .parent()
        .filter(|parent| !parent.as_os_str().is_empty())
        .ok_or_else(|| format!("TLS identity path has no parent: {}", path.display()))?;
    fs::create_dir_all(parent)
        .map_err(|error| format!("could not create {}: {error}", parent.display()))
}

fn write_private_key(path: &Path, contents: &[u8]) -> Result<(), String> {
    atomic_write(path, contents)?;
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        fs::set_permissions(path, fs::Permissions::from_mode(0o600)).map_err(|error| {
            format!("could not protect private key {}: {error}", path.display())
        })?;
    }
    Ok(())
}

fn atomic_write(path: &Path, contents: &[u8]) -> Result<(), String> {
    let file_name = path
        .file_name()
        .and_then(|value| value.to_str())
        .ok_or_else(|| format!("TLS identity path is invalid: {}", path.display()))?;
    let temporary = path.with_file_name(format!(".{file_name}.{}.tmp", std::process::id()));
    fs::write(&temporary, contents)
        .map_err(|error| format!("could not write {}: {error}", temporary.display()))?;
    fs::rename(&temporary, path).map_err(|error| {
        let _ = fs::remove_file(&temporary);
        format!("could not install {}: {error}", path.display())
    })
}
