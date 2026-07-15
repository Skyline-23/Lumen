use super::*;

pub(super) fn validate_settings(settings: &HostSettings) -> Result<(), SettingsProtocolError> {
    let name = settings.general.name.trim();
    if name.is_empty() || name.chars().count() > 64 || contains_control(name) {
        return Err(SettingsProtocolError::field(
            SettingsErrorCode::InvalidValue,
            "general.name",
            "host name must be 1 to 64 printable characters",
        ));
    }
    for (key, value) in [
        (
            "streaming.adapterSelector",
            &settings.streaming.adapter_selector,
        ),
        (
            "streaming.outputSelector",
            &settings.streaming.output_selector,
        ),
        ("audio.sink", &settings.audio.sink),
    ] {
        if value.len() > 256 || contains_control(value) {
            return Err(SettingsProtocolError::field(
                SettingsErrorCode::InvalidValue,
                key,
                "selector must be at most 256 printable characters",
            ));
        }
    }
    if !is_fallback_display_mode(&settings.streaming.fallback_display_mode) {
        return Err(SettingsProtocolError::field(
            SettingsErrorCode::InvalidValue,
            "streaming.fallbackDisplayMode",
            "fallback display mode must use WIDTHxHEIGHTxREFRESH format",
        ));
    }
    if !(-1..=60_000).contains(&settings.input.back_button_timeout_ms) {
        return Err(SettingsProtocolError::field(
            SettingsErrorCode::InvalidValue,
            "input.backButtonTimeoutMs",
            "back button timeout must be between -1 and 60000",
        ));
    }
    if !(1_029..=65_515).contains(&settings.network.port) {
        return Err(SettingsProtocolError::field(
            SettingsErrorCode::InvalidValue,
            "network.port",
            "port must be between 1029 and 65515",
        ));
    }
    if !(1_000..=120_000).contains(&settings.network.ping_timeout_ms) {
        return Err(SettingsProtocolError::field(
            SettingsErrorCode::InvalidValue,
            "network.pingTimeoutMs",
            "ping timeout must be between 1000 and 120000",
        ));
    }
    if !(1..=255).contains(&settings.network.fec_percentage) {
        return Err(SettingsProtocolError::field(
            SettingsErrorCode::InvalidValue,
            "network.fecPercentage",
            "FEC percentage must be between 1 and 255",
        ));
    }
    validate_commands(&settings.commands)
}

pub(super) fn contains_control(value: &str) -> bool {
    value.chars().any(char::is_control)
}

pub(super) fn is_fallback_display_mode(value: &str) -> bool {
    let mut pieces = value.split('x');
    let Some(width) = pieces.next() else {
        return false;
    };
    let Some(height) = pieces.next() else {
        return false;
    };
    let Some(refresh) = pieces.next() else {
        return false;
    };
    pieces.next().is_none()
        && positive_decimal_integer(width)
        && positive_decimal_integer(height)
        && positive_decimal_number(refresh)
}

pub(super) fn positive_decimal_integer(value: &str) -> bool {
    !value.is_empty()
        && value.bytes().all(|byte| byte.is_ascii_digit())
        && value.parse::<u32>().is_ok_and(|value| value > 0)
}

pub(super) fn positive_decimal_number(value: &str) -> bool {
    let mut pieces = value.split('.');
    let Some(integer) = pieces.next() else {
        return false;
    };
    let fractional = pieces.next();
    if pieces.next().is_some()
        || !positive_decimal_integer(integer)
        || fractional
            .is_some_and(|part| part.is_empty() || !part.bytes().all(|byte| byte.is_ascii_digit()))
    {
        return false;
    }
    value
        .parse::<f64>()
        .is_ok_and(|value| value.is_finite() && value > 0.0)
}

pub(super) fn validate_commands(commands: &CommandsSettings) -> Result<(), SettingsProtocolError> {
    for (key, count) in [
        ("commands.prep", commands.prep.len()),
        ("commands.state", commands.state.len()),
        ("commands.server", commands.server.len()),
    ] {
        if count > MAXIMUM_COMMANDS_PER_LIST {
            return Err(SettingsProtocolError::field(
                SettingsErrorCode::InvalidValue,
                key,
                "command list exceeds 64 entries",
            ));
        }
    }
    for command in commands.prep.iter().chain(commands.state.iter()) {
        validate_invocation(&command.run)?;
        if let Some(undo) = &command.undo {
            validate_invocation(undo)?;
        }
    }
    let mut names = std::collections::BTreeSet::new();
    for command in &commands.server {
        if command.name.trim().is_empty()
            || command.name.chars().count() > 64
            || contains_control(&command.name)
        {
            return Err(SettingsProtocolError::field(
                SettingsErrorCode::InvalidValue,
                "commands.server.name",
                "server command name must be 1 to 64 printable characters",
            ));
        }
        if !names.insert(command.name.to_ascii_lowercase()) {
            return Err(SettingsProtocolError::field(
                SettingsErrorCode::InvalidValue,
                "commands.server.name",
                "server command names must be unique",
            ));
        }
        validate_invocation(&command.invocation)?;
    }
    Ok(())
}

pub(super) fn validate_invocation(
    invocation: &CommandInvocation,
) -> Result<(), SettingsProtocolError> {
    if invocation.program.is_empty()
        || invocation.program.len() > 128
        || !invocation
            .program
            .bytes()
            .all(|byte| byte.is_ascii_alphanumeric() || matches!(byte, b'.' | b'_' | b'-'))
    {
        return Err(SettingsProtocolError::field(
            SettingsErrorCode::InvalidValue,
            "commands.program",
            "program must be a portable identifier without a path or shell syntax",
        ));
    }
    if matches!(
        invocation.program.to_ascii_lowercase().as_str(),
        "sh" | "bash"
            | "zsh"
            | "fish"
            | "cmd"
            | "cmd.exe"
            | "powershell"
            | "powershell.exe"
            | "pwsh"
            | "wscript"
            | "cscript"
    ) {
        return Err(SettingsProtocolError::field(
            SettingsErrorCode::InvalidValue,
            "commands.program",
            "shell interpreters are not accepted by the argv command contract",
        ));
    }
    if invocation.arguments.len() > MAXIMUM_ARGUMENTS_PER_INVOCATION {
        return Err(SettingsProtocolError::field(
            SettingsErrorCode::InvalidValue,
            "commands.arguments",
            "command invocation exceeds 64 arguments",
        ));
    }
    if invocation
        .arguments
        .iter()
        .any(|argument| argument.len() > MAXIMUM_ARGUMENT_LENGTH || contains_control(argument))
    {
        return Err(SettingsProtocolError::field(
            SettingsErrorCode::InvalidValue,
            "commands.arguments",
            "command arguments must be printable and at most 1024 bytes",
        ));
    }
    Ok(())
}

pub(super) fn request_fingerprint(
    request: &SettingsPatchRequest,
) -> Result<String, SettingsProtocolError> {
    let data = serde_json::to_vec(request).map_err(|_| {
        SettingsProtocolError::new(
            SettingsErrorCode::InvalidRequest,
            "patch request could not be canonicalized",
        )
    })?;
    let digest = Sha256::digest(data);
    Ok(digest.iter().map(|byte| format!("{byte:02x}")).collect())
}
