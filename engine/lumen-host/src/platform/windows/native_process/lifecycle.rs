use std::sync::Mutex;

use lumen_engine::settings::{CommandInvocation, CommandPrivilege, PrepCommand, ServerCommand};

use crate::PlatformApplicationPlan;

use super::adapter::NativeWindowsProcess;
use crate::platform::application_environment::{application_environment, expand};

struct RunningApplication {
    process: NativeWindowsProcess,
    working_directory: String,
    state_undo_commands: Vec<UndoCommand>,
    prep_undo_commands: Vec<UndoCommand>,
    server_commands: Vec<ServerCommand>,
    exit_timeout_seconds: u32,
}

enum UndoCommand {
    Text {
        command: String,
        elevated: bool,
    },
    Structured {
        invocation: CommandInvocation,
        elevated: bool,
    },
}

#[derive(Default)]
pub(crate) struct NativeWindowsApplication {
    running: Mutex<Option<RunningApplication>>,
}

impl NativeWindowsApplication {
    pub(crate) fn start(&self, plan: PlatformApplicationPlan) -> Result<(), String> {
        let mut running = self
            .running
            .lock()
            .map_err(|_| "Windows application state lock is poisoned".to_owned())?;
        if running.is_some() {
            return Err("A Windows application is already running".to_owned());
        }

        let environment = application_environment(&plan.application, &plan)?;
        let global_prep_commands = plan.global_prep_commands;
        let global_state_commands = plan.global_state_commands;
        let application = plan.application;
        let working_directory = expand(&application.working_directory, &environment)?;
        let output = expand(&application.output, &environment)?;
        let application_prep_commands = application
            .prep_commands
            .iter()
            .map(|command| {
                Ok((
                    expand(&command.run, &environment)?,
                    expand(&command.undo, &environment)?,
                    command.elevated,
                ))
            })
            .collect::<Result<Vec<_>, String>>()?;
        let application_state_commands = application
            .state_commands
            .iter()
            .map(|command| {
                Ok((
                    expand(&command.run, &environment)?,
                    expand(&command.undo, &environment)?,
                    command.elevated,
                ))
            })
            .collect::<Result<Vec<_>, String>>()?;
        let detached_commands = application
            .detached_commands
            .iter()
            .map(|command| expand(command, &environment))
            .collect::<Result<Vec<_>, String>>()?;
        let command = expand(&application.command, &environment)?;
        let process = NativeWindowsProcess::new(&environment, &output)?;
        let mut completed_prep = Vec::new();

        for command in global_prep_commands {
            if let Err(error) = run_structured(&process, &working_directory, &command) {
                rollback(&process, &working_directory, &completed_prep);
                return Err(error);
            }
            if let Some(undo) = command.undo {
                completed_prep.push(UndoCommand::Structured {
                    invocation: undo,
                    elevated: is_elevated(command.privilege),
                });
            }
        }

        for (run, undo, elevated) in application_prep_commands {
            if run.is_empty() {
                continue;
            }
            if let Err(error) = process.run_blocking(&run, &working_directory, elevated) {
                rollback(&process, &working_directory, &completed_prep);
                return Err(error);
            }
            completed_prep.push(UndoCommand::Text {
                command: undo,
                elevated,
            });
        }

        for command in detached_commands {
            if command.is_empty() {
                continue;
            }
            if let Err(error) =
                process.spawn_detached(&command, &working_directory, application.elevated)
            {
                rollback(&process, &working_directory, &completed_prep);
                return Err(error);
            }
        }

        if !command.is_empty() {
            if let Err(error) =
                process.spawn_main(&command, &working_directory, application.elevated)
            {
                rollback(&process, &working_directory, &completed_prep);
                return Err(error);
            }
        }

        let mut completed_state = Vec::new();
        for command in global_state_commands {
            if let Err(error) = run_structured(&process, &working_directory, &command) {
                rollback(&process, &working_directory, &completed_state);
                let _ = process.stop_main(0);
                rollback(&process, &working_directory, &completed_prep);
                return Err(error);
            }
            if let Some(undo) = command.undo {
                completed_state.push(UndoCommand::Structured {
                    invocation: undo,
                    elevated: is_elevated(command.privilege),
                });
            }
        }
        for (run, undo, elevated) in application_state_commands {
            if run.is_empty() {
                continue;
            }
            if let Err(error) = process.run_blocking(&run, &working_directory, elevated) {
                rollback(&process, &working_directory, &completed_state);
                let _ = process.stop_main(0);
                rollback(&process, &working_directory, &completed_prep);
                return Err(error);
            }
            completed_state.push(UndoCommand::Text {
                command: undo,
                elevated,
            });
        }

        *running = Some(RunningApplication {
            process,
            working_directory,
            state_undo_commands: completed_state,
            prep_undo_commands: completed_prep,
            server_commands: plan.server_commands,
            exit_timeout_seconds: application.exit_timeout_seconds,
        });
        Ok(())
    }

    pub(crate) fn stop(&self) -> Result<(), String> {
        let mut running = self
            .running
            .lock()
            .map_err(|_| "Windows application state lock is poisoned".to_owned())?;
        let Some(application) = running.take() else {
            return Ok(());
        };
        let mut failures = Vec::new();
        collect_undo_failures(
            &application.process,
            &application.working_directory,
            &application.state_undo_commands,
            &mut failures,
        );
        if let Err(error) = application
            .process
            .stop_main(application.exit_timeout_seconds)
        {
            failures.push(error);
        }
        collect_undo_failures(
            &application.process,
            &application.working_directory,
            &application.prep_undo_commands,
            &mut failures,
        );
        if failures.is_empty() {
            Ok(())
        } else {
            Err(failures.join("; "))
        }
    }

    pub(crate) fn execute_server_command(&self, index: u8) -> Result<(), String> {
        let running = self
            .running
            .lock()
            .map_err(|_| "Windows application state lock is poisoned".to_owned())?;
        let application = running
            .as_ref()
            .ok_or_else(|| "No Windows application is running".to_owned())?;
        let command = application
            .server_commands
            .get(usize::from(index))
            .ok_or_else(|| format!("Server command index {index} is invalid"))?;
        application.process.spawn_invocation(
            &command.invocation,
            &application.working_directory,
            is_elevated(command.privilege),
        )
    }
}

impl Drop for NativeWindowsApplication {
    fn drop(&mut self) {
        let _ = self.stop();
    }
}

fn rollback(process: &NativeWindowsProcess, working_directory: &str, commands: &[UndoCommand]) {
    for command in commands.iter().rev() {
        let _ = run_undo(process, working_directory, command);
    }
}

fn collect_undo_failures(
    process: &NativeWindowsProcess,
    working_directory: &str,
    commands: &[UndoCommand],
    failures: &mut Vec<String>,
) {
    for command in commands.iter().rev() {
        if let Err(error) = run_undo(process, working_directory, command) {
            failures.push(error);
        }
    }
}

fn run_structured(
    process: &NativeWindowsProcess,
    working_directory: &str,
    command: &PrepCommand,
) -> Result<(), String> {
    process.run_invocation(
        &command.run,
        working_directory,
        is_elevated(command.privilege),
    )
}

fn run_undo(
    process: &NativeWindowsProcess,
    working_directory: &str,
    command: &UndoCommand,
) -> Result<(), String> {
    match command {
        UndoCommand::Text { command, .. } if command.is_empty() => Ok(()),
        UndoCommand::Text { command, elevated } => {
            process.run_blocking(command, working_directory, *elevated)
        }
        UndoCommand::Structured {
            invocation,
            elevated,
        } => process.run_invocation(invocation, working_directory, *elevated),
    }
}

fn is_elevated(privilege: CommandPrivilege) -> bool {
    privilege == CommandPrivilege::Administrator
}
