use std::collections::BTreeMap;
use std::fs::{File, OpenOptions};
use std::process::{Child, Command, Stdio};
use std::sync::Mutex;

use lumen_engine::settings::{CommandInvocation, CommandPrivilege, PrepCommand, ServerCommand};

use super::application_environment::{application_environment, expand};
use crate::PlatformApplicationPlan;

struct RunningApplication {
    main: Option<Child>,
    detached: Vec<Child>,
    environment: BTreeMap<String, String>,
    working_directory: String,
    output: Option<File>,
    state_undo: Vec<CommandSpec>,
    prep_undo: Vec<CommandSpec>,
    server_commands: Vec<ServerCommand>,
}

enum CommandSpec {
    Text(String),
    Structured(CommandInvocation),
}

#[derive(Default)]
pub(super) struct PortableApplication {
    running: Mutex<Option<RunningApplication>>,
}

impl PortableApplication {
    pub(super) fn start(&self, plan: PlatformApplicationPlan) -> Result<(), String> {
        let mut running = self
            .running
            .lock()
            .map_err(|_| "portable application state lock is poisoned".to_owned())?;
        if running.is_some() {
            return Err("an application is already running".to_owned());
        }

        let environment = application_environment(&plan.application, &plan)?;
        let application = plan.application;
        if application.elevated {
            return Err("elevated application launch is unavailable on this platform".to_owned());
        }
        let working_directory = expand(&application.working_directory, &environment)?;
        let output_path = expand(&application.output, &environment)?;
        let output = open_output(&output_path)?;
        let mut prep_undo = Vec::new();

        for command in plan.global_prep_commands {
            if let Err(error) =
                run_structured(&command, &environment, &working_directory, output.as_ref())
            {
                rollback(
                    &prep_undo,
                    &environment,
                    &working_directory,
                    output.as_ref(),
                );
                return Err(error);
            }
            if let Some(undo) = command.undo {
                prep_undo.push(CommandSpec::Structured(undo));
            }
        }
        for command in &application.prep_commands {
            let run = match expand(&command.run, &environment) {
                Ok(run) => run,
                Err(error) => {
                    rollback(
                        &prep_undo,
                        &environment,
                        &working_directory,
                        output.as_ref(),
                    );
                    return Err(error);
                }
            };
            if run.is_empty() {
                continue;
            }
            let undo = match expand(&command.undo, &environment) {
                Ok(undo) => undo,
                Err(error) => {
                    rollback(
                        &prep_undo,
                        &environment,
                        &working_directory,
                        output.as_ref(),
                    );
                    return Err(error);
                }
            };
            if command.elevated {
                rollback(
                    &prep_undo,
                    &environment,
                    &working_directory,
                    output.as_ref(),
                );
                return Err(
                    "elevated application command is unavailable on this platform".to_owned(),
                );
            }
            if let Err(error) = run_text(&run, &environment, &working_directory, output.as_ref()) {
                rollback(
                    &prep_undo,
                    &environment,
                    &working_directory,
                    output.as_ref(),
                );
                return Err(error);
            }
            prep_undo.push(CommandSpec::Text(undo));
        }

        let mut detached = Vec::new();
        for command in &application.detached_commands {
            let command = match expand(command, &environment) {
                Ok(command) => command,
                Err(error) => {
                    rollback(
                        &prep_undo,
                        &environment,
                        &working_directory,
                        output.as_ref(),
                    );
                    return Err(error);
                }
            };
            if !command.is_empty() {
                let child = spawn_text(&command, &environment, &working_directory, output.as_ref());
                match child {
                    Ok(child) => detached.push(child),
                    Err(error) => {
                        rollback(
                            &prep_undo,
                            &environment,
                            &working_directory,
                            output.as_ref(),
                        );
                        return Err(error);
                    }
                }
            }
        }
        let command = match expand(&application.command, &environment) {
            Ok(command) => command,
            Err(error) => {
                rollback(
                    &prep_undo,
                    &environment,
                    &working_directory,
                    output.as_ref(),
                );
                return Err(error);
            }
        };
        let mut main = if command.is_empty() {
            None
        } else {
            match spawn_text(&command, &environment, &working_directory, output.as_ref()) {
                Ok(child) => Some(child),
                Err(error) => {
                    rollback(
                        &prep_undo,
                        &environment,
                        &working_directory,
                        output.as_ref(),
                    );
                    return Err(error);
                }
            }
        };

        let mut state_undo = Vec::new();
        for command in plan.global_state_commands {
            if let Err(error) =
                run_structured(&command, &environment, &working_directory, output.as_ref())
            {
                rollback(
                    &state_undo,
                    &environment,
                    &working_directory,
                    output.as_ref(),
                );
                stop_main(&mut main);
                rollback(
                    &prep_undo,
                    &environment,
                    &working_directory,
                    output.as_ref(),
                );
                return Err(error);
            }
            if let Some(undo) = command.undo {
                state_undo.push(CommandSpec::Structured(undo));
            }
        }
        for command in &application.state_commands {
            let run = match expand(&command.run, &environment) {
                Ok(run) => run,
                Err(error) => {
                    rollback(
                        &state_undo,
                        &environment,
                        &working_directory,
                        output.as_ref(),
                    );
                    stop_main(&mut main);
                    rollback(
                        &prep_undo,
                        &environment,
                        &working_directory,
                        output.as_ref(),
                    );
                    return Err(error);
                }
            };
            if !run.is_empty() {
                let undo = match expand(&command.undo, &environment) {
                    Ok(undo) => undo,
                    Err(error) => {
                        rollback(
                            &state_undo,
                            &environment,
                            &working_directory,
                            output.as_ref(),
                        );
                        stop_main(&mut main);
                        rollback(
                            &prep_undo,
                            &environment,
                            &working_directory,
                            output.as_ref(),
                        );
                        return Err(error);
                    }
                };
                if let Err(error) =
                    run_text(&run, &environment, &working_directory, output.as_ref())
                {
                    rollback(
                        &state_undo,
                        &environment,
                        &working_directory,
                        output.as_ref(),
                    );
                    stop_main(&mut main);
                    rollback(
                        &prep_undo,
                        &environment,
                        &working_directory,
                        output.as_ref(),
                    );
                    return Err(error);
                }
                state_undo.push(CommandSpec::Text(undo));
            }
        }

        *running = Some(RunningApplication {
            main,
            detached,
            environment,
            working_directory,
            output,
            state_undo,
            prep_undo,
            server_commands: plan.server_commands,
        });
        Ok(())
    }

    pub(super) fn stop(&self) -> Result<(), String> {
        let mut running = self
            .running
            .lock()
            .map_err(|_| "portable application state lock is poisoned".to_owned())?;
        let Some(mut application) = running.take() else {
            return Ok(());
        };
        let mut failures = Vec::new();
        collect_undo_failures(
            &application.state_undo,
            &application.environment,
            &application.working_directory,
            application.output.as_ref(),
            &mut failures,
        );
        if let Some(mut child) = application.main.take() {
            if child
                .try_wait()
                .map_err(|error| error.to_string())?
                .is_none()
            {
                if let Err(error) = child.kill().and_then(|_| child.wait()) {
                    failures.push(error.to_string());
                }
            }
        }
        for child in &mut application.detached {
            let _ = child.try_wait();
        }
        collect_undo_failures(
            &application.prep_undo,
            &application.environment,
            &application.working_directory,
            application.output.as_ref(),
            &mut failures,
        );
        if failures.is_empty() {
            Ok(())
        } else {
            Err(failures.join("; "))
        }
    }

    pub(super) fn execute_server_command(&self, index: u8) -> Result<(), String> {
        let mut running = self
            .running
            .lock()
            .map_err(|_| "portable application state lock is poisoned".to_owned())?;
        let application = running
            .as_mut()
            .ok_or_else(|| "no application is running".to_owned())?;
        let command = application
            .server_commands
            .get(usize::from(index))
            .ok_or_else(|| format!("server command index {index} is invalid"))?;
        if command.privilege != CommandPrivilege::User {
            return Err("elevated server command is unavailable on this platform".to_owned());
        }
        let mut process = invocation_command(&command.invocation);
        configure(
            &mut process,
            &application.environment,
            &application.working_directory,
            application.output.as_ref(),
        )?;
        application
            .detached
            .push(process.spawn().map_err(|error| error.to_string())?);
        Ok(())
    }
}

impl Drop for PortableApplication {
    fn drop(&mut self) {
        let _ = self.stop();
    }
}

fn stop_main(main: &mut Option<Child>) {
    let Some(mut child) = main.take() else {
        return;
    };
    if child.try_wait().ok().flatten().is_none() {
        let _ = child.kill().and_then(|_| child.wait());
    }
}

fn run_structured(
    command: &PrepCommand,
    environment: &BTreeMap<String, String>,
    working_directory: &str,
    output: Option<&File>,
) -> Result<(), String> {
    if command.privilege != CommandPrivilege::User {
        return Err("elevated structured command is unavailable on this platform".to_owned());
    }
    run_invocation(&command.run, environment, working_directory, output)
}

fn run_invocation(
    invocation: &CommandInvocation,
    environment: &BTreeMap<String, String>,
    working_directory: &str,
    output: Option<&File>,
) -> Result<(), String> {
    let mut command = invocation_command(invocation);
    configure(&mut command, environment, working_directory, output)?;
    let status = command.status().map_err(|error| error.to_string())?;
    status
        .success()
        .then_some(())
        .ok_or_else(|| format!("structured command exited with {status}"))
}

fn invocation_command(invocation: &CommandInvocation) -> Command {
    let mut command = Command::new(&invocation.program);
    command.args(&invocation.arguments);
    command
}

fn run_text(
    value: &str,
    environment: &BTreeMap<String, String>,
    working_directory: &str,
    output: Option<&File>,
) -> Result<(), String> {
    let mut command = text_command(value)?;
    configure(&mut command, environment, working_directory, output)?;
    let status = command.status().map_err(|error| error.to_string())?;
    status
        .success()
        .then_some(())
        .ok_or_else(|| format!("application command exited with {status}"))
}

fn spawn_text(
    value: &str,
    environment: &BTreeMap<String, String>,
    working_directory: &str,
    output: Option<&File>,
) -> Result<Child, String> {
    let mut command = text_command(value)?;
    configure(&mut command, environment, working_directory, output)?;
    command.spawn().map_err(|error| error.to_string())
}

fn text_command(value: &str) -> Result<Command, String> {
    let arguments = shlex::split(value)
        .ok_or_else(|| "application command contains invalid quoting".to_owned())?;
    let (program, arguments) = arguments
        .split_first()
        .ok_or_else(|| "application command is empty".to_owned())?;
    let mut command = Command::new(program);
    command.args(arguments);
    Ok(command)
}

fn configure(
    command: &mut Command,
    environment: &BTreeMap<String, String>,
    working_directory: &str,
    output: Option<&File>,
) -> Result<(), String> {
    command.env_clear().envs(environment);
    if !working_directory.is_empty() {
        command.current_dir(working_directory);
    }
    if let Some(output) = output {
        command.stdout(Stdio::from(
            output.try_clone().map_err(|error| error.to_string())?,
        ));
        command.stderr(Stdio::from(
            output.try_clone().map_err(|error| error.to_string())?,
        ));
    } else {
        command.stdout(Stdio::null()).stderr(Stdio::null());
    }
    Ok(())
}

fn open_output(path: &str) -> Result<Option<File>, String> {
    if path.is_empty() || path == "null" {
        return Ok(None);
    }
    OpenOptions::new()
        .create(true)
        .append(true)
        .open(path)
        .map(Some)
        .map_err(|error| error.to_string())
}

fn rollback(
    commands: &[CommandSpec],
    environment: &BTreeMap<String, String>,
    working_directory: &str,
    output: Option<&File>,
) {
    for command in commands.iter().rev() {
        let _ = run_undo(command, environment, working_directory, output);
    }
}

fn collect_undo_failures(
    commands: &[CommandSpec],
    environment: &BTreeMap<String, String>,
    working_directory: &str,
    output: Option<&File>,
    failures: &mut Vec<String>,
) {
    for command in commands.iter().rev() {
        if let Err(error) = run_undo(command, environment, working_directory, output) {
            failures.push(error);
        }
    }
}

fn run_undo(
    command: &CommandSpec,
    environment: &BTreeMap<String, String>,
    working_directory: &str,
    output: Option<&File>,
) -> Result<(), String> {
    match command {
        CommandSpec::Text(command) if command.is_empty() => Ok(()),
        CommandSpec::Text(command) => run_text(command, environment, working_directory, output),
        CommandSpec::Structured(command) => {
            run_invocation(command, environment, working_directory, output)
        }
    }
}
