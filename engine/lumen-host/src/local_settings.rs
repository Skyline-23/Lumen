use lumen_engine::settings::{
    AddressFamily, CommandInvocation, CommandPrivilege, CommandsSettings, EncryptionMode,
    HostSettings, LogLevel, PrepCommand, RemoteAccessScope, ServerCommand, WorkspacePolicy,
};
use serde::Deserialize;

use crate::{network_ports::HostPorts, HostArguments};

#[derive(Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct NativePrepCommand {
    run: String,
    undo: String,
    privilege: CommandPrivilege,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct NativeServerCommand {
    name: String,
    command: String,
    privilege: CommandPrivilege,
}

pub(super) fn from_arguments(
    arguments: &HostArguments,
    mut settings: HostSettings,
) -> Result<HostSettings, String> {
    settings.workspace.policy = one_of(
        arguments,
        "workspace_policy",
        &[
            ("coexist", WorkspacePolicy::Coexist),
            ("promote-virtual-main", WorkspacePolicy::PromoteVirtualMain),
            ("focused-workspace", WorkspacePolicy::FocusedWorkspace),
            ("isolated-workspace", WorkspacePolicy::IsolatedWorkspace),
        ],
    )?;
    settings.general.name = text(arguments, "host_name")?.to_owned();
    settings.general.discovery = boolean(arguments, "enable_discovery")?;
    settings.general.notify_pre_releases = boolean(arguments, "notify_pre_releases")?;
    settings.streaming.adapter_selector = selector(arguments, "adapter_name", "automatic");
    #[cfg(not(windows))]
    {
        settings.streaming.output_selector = selector(arguments, "output_name", "automatic");
    }
    #[cfg(windows)]
    {
        settings.streaming.output_selector = "automatic".to_owned();
    }
    settings.streaming.fallback_display_mode = text(arguments, "fallback_mode")?.to_owned();
    settings.audio.sink = selector(arguments, "audio_sink", "system-default");
    settings.audio.stream_audio = boolean(arguments, "stream_audio")?;
    settings.input.keyboard = boolean(arguments, "keyboard")?;
    settings.input.mouse = boolean(arguments, "mouse")?;
    settings.input.controller = boolean(arguments, "controller")?;
    settings.input.back_button_timeout_ms = number(arguments, "back_button_timeout")?;
    settings.input.map_right_alt_to_windows_key = boolean(arguments, "key_rightalt_to_key_win")?;
    settings.input.high_resolution_scrolling = boolean(arguments, "high_resolution_scrolling")?;
    settings.input.native_pen_touch = boolean(arguments, "native_pen_touch")?;
    settings.input.rumble_forwarding = boolean(arguments, "forward_rumble")?;
    settings.network.address_family = one_of(
        arguments,
        "address_family",
        &[("ipv4", AddressFamily::Ipv4), ("both", AddressFamily::Both)],
    )?;
    settings.network.port = HostPorts::from_arguments(arguments)?.control_https;
    settings.network.upnp = boolean(arguments, "upnp")?;
    settings.network.remote_access_scope = one_of(
        arguments,
        "origin_admin_allowed",
        &[
            ("pc", RemoteAccessScope::Pc),
            ("lan", RemoteAccessScope::Lan),
            ("wan", RemoteAccessScope::Wan),
        ],
    )?;
    settings.network.lan_encryption = encryption(arguments, "lan_encryption_mode")?;
    settings.network.wan_encryption = encryption(arguments, "wan_encryption_mode")?;
    settings.network.ping_timeout_ms = number(arguments, "ping_timeout")?;
    settings.network.fec_percentage = number(arguments, "fec_percentage")?;
    settings.diagnostics.log_level = one_of(
        arguments,
        "min_log_level",
        &[
            ("verbose", LogLevel::Verbose),
            ("debug", LogLevel::Debug),
            ("info", LogLevel::Info),
            ("warning", LogLevel::Warning),
            ("error", LogLevel::Error),
            ("fatal", LogLevel::Fatal),
            ("none", LogLevel::None),
        ],
    )?;
    settings.commands = commands(arguments)?;
    Ok(settings)
}

fn commands(arguments: &HostArguments) -> Result<CommandsSettings, String> {
    let prep = parse_json::<NativePrepCommand>(arguments, "global_prep_cmd")?
        .into_iter()
        .map(prep_command)
        .collect::<Result<Vec<_>, _>>()?;
    let state = parse_json::<NativePrepCommand>(arguments, "global_state_cmd")?
        .into_iter()
        .map(prep_command)
        .collect::<Result<Vec<_>, _>>()?;
    let server = parse_json::<NativeServerCommand>(arguments, "server_cmd")?
        .into_iter()
        .map(|command| {
            Ok(ServerCommand {
                name: command.name,
                invocation: invocation(&command.command)?,
                privilege: command.privilege,
            })
        })
        .collect::<Result<Vec<_>, String>>()?;
    Ok(CommandsSettings {
        prep,
        state,
        server,
    })
}

fn parse_json<T>(arguments: &HostArguments, key: &str) -> Result<Vec<T>, String>
where
    T: for<'de> Deserialize<'de>,
{
    serde_json::from_str(text(arguments, key)?)
        .map_err(|_| format!("{key} does not match the native command schema"))
}

fn prep_command(command: NativePrepCommand) -> Result<PrepCommand, String> {
    Ok(PrepCommand {
        run: invocation(&command.run)?,
        undo: (!command.undo.is_empty())
            .then(|| invocation(&command.undo))
            .transpose()?,
        privilege: command.privilege,
    })
}

fn invocation(command: &str) -> Result<CommandInvocation, String> {
    let values = shlex::split(command)
        .ok_or_else(|| "native command contains invalid quoting".to_owned())?;
    let (program, arguments) = values
        .split_first()
        .ok_or_else(|| "native command is empty".to_owned())?;
    Ok(CommandInvocation {
        program: program.clone(),
        arguments: arguments.to_vec(),
    })
}

fn encryption(arguments: &HostArguments, key: &str) -> Result<EncryptionMode, String> {
    one_of(
        arguments,
        key,
        &[
            ("0", EncryptionMode::Disabled),
            ("1", EncryptionMode::Opportunistic),
            ("2", EncryptionMode::Required),
        ],
    )
}

fn text<'a>(arguments: &'a HostArguments, key: &str) -> Result<&'a str, String> {
    arguments
        .get(key)
        .ok_or_else(|| format!("native runtime setting {key} is missing"))
}

fn selector(arguments: &HostArguments, key: &str, fallback: &str) -> String {
    arguments.get(key).unwrap_or(fallback).to_owned()
}

fn boolean(arguments: &HostArguments, key: &str) -> Result<bool, String> {
    one_of(arguments, key, &[("true", true), ("false", false)])
}

fn number<T>(arguments: &HostArguments, key: &str) -> Result<T, String>
where
    T: std::str::FromStr,
{
    text(arguments, key)?
        .parse()
        .map_err(|_| format!("native runtime setting {key} is invalid"))
}

fn one_of<T: Copy>(
    arguments: &HostArguments,
    key: &str,
    values: &[(&str, T)],
) -> Result<T, String> {
    let value = text(arguments, key)?;
    values
        .iter()
        .find_map(|(candidate, parsed)| (*candidate == value).then_some(*parsed))
        .ok_or_else(|| format!("native runtime setting {key} is invalid"))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn reconciles_native_runtime_groups_into_rust_settings() {
        let mut values = crate::config::tests::valid_arguments();
        for value in &mut values {
            if value.starts_with("workspace_policy=") {
                *value = "workspace_policy=isolated-workspace".to_owned();
            } else if value.starts_with("global_prep_cmd=") {
                *value = r#"global_prep_cmd=[{"run":"tool start","undo":"tool stop","privilege":"user"}]"#.to_owned();
            } else if value.starts_with("server_cmd=") {
                *value = r#"server_cmd=[{"name":"Wake","command":"tool wake","privilege":"user"}]"#
                    .to_owned();
            }
        }
        let arguments = HostArguments::parse(values).unwrap();
        let settings = from_arguments(&arguments, HostSettings::default()).unwrap();
        assert_eq!(
            settings.workspace.policy,
            WorkspacePolicy::IsolatedWorkspace
        );
        assert_eq!(settings.commands.prep[0].run.program, "tool");
        assert_eq!(settings.commands.prep[0].run.arguments, ["start"]);
        assert_eq!(settings.commands.server[0].invocation.arguments, ["wake"]);
        assert!(settings.general.discovery);
        assert!(settings.network.upnp);
        assert_eq!(settings.network.port, 47_990);
    }
}
