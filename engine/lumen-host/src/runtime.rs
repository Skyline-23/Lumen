use std::fmt;

use crate::HostArguments;

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum HostCommand {
    ForceStopStream,
    ReloadApplications,
    Restart,
    Shutdown,
}

#[derive(Clone, Copy, Debug, Default, Eq, PartialEq)]
pub enum HostRuntimeState {
    #[default]
    Created,
    Running,
    Stopped,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub enum HostRuntimeError {
    InvalidState {
        expected: HostRuntimeState,
        actual: HostRuntimeState,
    },
    Service {
        operation: &'static str,
        message: String,
    },
}

impl fmt::Display for HostRuntimeError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::InvalidState { expected, actual } => {
                write!(
                    formatter,
                    "expected {expected:?} host state, found {actual:?}"
                )
            }
            Self::Service { operation, message } => {
                write!(formatter, "host service {operation} failed: {message}")
            }
        }
    }
}

impl std::error::Error for HostRuntimeError {}

pub trait HostService {
    fn start(&mut self, arguments: &HostArguments) -> Result<(), String>;
    fn force_stop_stream(&mut self) -> Result<(), String>;
    fn reload_applications(&mut self) -> Result<(), String>;
    fn stop(&mut self) -> Result<(), String>;
}

pub struct HostRuntime<S> {
    service: S,
    state: HostRuntimeState,
}

impl<S: HostService> HostRuntime<S> {
    pub fn new(service: S) -> Self {
        Self {
            service,
            state: HostRuntimeState::Created,
        }
    }

    pub fn state(&self) -> HostRuntimeState {
        self.state
    }

    pub fn service(&self) -> &S {
        &self.service
    }

    pub fn start(&mut self, arguments: &HostArguments) -> Result<(), HostRuntimeError> {
        if self.state != HostRuntimeState::Created {
            return Err(HostRuntimeError::InvalidState {
                expected: HostRuntimeState::Created,
                actual: self.state,
            });
        }
        self.service
            .start(arguments)
            .map_err(|message| HostRuntimeError::Service {
                operation: "start",
                message,
            })?;
        self.state = HostRuntimeState::Running;
        Ok(())
    }

    pub fn handle(&mut self, command: HostCommand) -> Result<(), HostRuntimeError> {
        if self.state != HostRuntimeState::Running {
            return Err(HostRuntimeError::InvalidState {
                expected: HostRuntimeState::Running,
                actual: self.state,
            });
        }
        match command {
            HostCommand::ForceStopStream => {
                self.service
                    .force_stop_stream()
                    .map_err(|message| HostRuntimeError::Service {
                        operation: "force-stop-stream",
                        message,
                    })
            }
            HostCommand::ReloadApplications => {
                self.service
                    .reload_applications()
                    .map_err(|message| HostRuntimeError::Service {
                        operation: "reload-applications",
                        message,
                    })
            }
            HostCommand::Restart | HostCommand::Shutdown => self.stop(),
        }
    }

    pub fn stop(&mut self) -> Result<(), HostRuntimeError> {
        if self.state == HostRuntimeState::Stopped {
            return Ok(());
        }
        if self.state != HostRuntimeState::Running {
            return Err(HostRuntimeError::InvalidState {
                expected: HostRuntimeState::Running,
                actual: self.state,
            });
        }
        self.service
            .stop()
            .map_err(|message| HostRuntimeError::Service {
                operation: "stop",
                message,
            })?;
        self.state = HostRuntimeState::Stopped;
        Ok(())
    }

    pub fn run_commands<I>(
        &mut self,
        arguments: &HostArguments,
        commands: I,
    ) -> Result<(), HostRuntimeError>
    where
        I: IntoIterator<Item = HostCommand>,
    {
        self.start(arguments)?;
        for command in commands {
            self.handle(command)?;
            if self.state == HostRuntimeState::Stopped {
                return Ok(());
            }
        }
        self.stop()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[derive(Default)]
    struct RecordingService {
        events: Vec<&'static str>,
        fail_reload: bool,
    }

    impl HostService for RecordingService {
        fn start(&mut self, _arguments: &HostArguments) -> Result<(), String> {
            self.events.push("start");
            Ok(())
        }

        fn force_stop_stream(&mut self) -> Result<(), String> {
            self.events.push("force-stop-stream");
            Ok(())
        }

        fn reload_applications(&mut self) -> Result<(), String> {
            self.events.push("reload-applications");
            if self.fail_reload {
                Err("reload rejected".to_owned())
            } else {
                Ok(())
            }
        }

        fn stop(&mut self) -> Result<(), String> {
            self.events.push("stop");
            Ok(())
        }
    }

    fn arguments() -> HostArguments {
        super::super::config::tests::valid_arguments_for_runtime_tests()
    }

    #[test]
    fn commands_flow_through_one_running_service_and_shutdown_once() {
        let mut runtime = HostRuntime::new(RecordingService::default());
        runtime
            .run_commands(
                &arguments(),
                [
                    HostCommand::ForceStopStream,
                    HostCommand::ReloadApplications,
                    HostCommand::Restart,
                ],
            )
            .unwrap();
        assert_eq!(runtime.state(), HostRuntimeState::Stopped);
        assert_eq!(
            runtime.service().events,
            ["start", "force-stop-stream", "reload-applications", "stop"]
        );
        runtime.stop().unwrap();
        assert_eq!(runtime.service().events.last(), Some(&"stop"));
    }

    #[test]
    fn service_failures_are_typed_and_do_not_claim_stopped_state() {
        let mut runtime = HostRuntime::new(RecordingService {
            fail_reload: true,
            ..RecordingService::default()
        });
        runtime.start(&arguments()).unwrap();
        assert_eq!(
            runtime.handle(HostCommand::ReloadApplications),
            Err(HostRuntimeError::Service {
                operation: "reload-applications",
                message: "reload rejected".to_owned(),
            })
        );
        assert_eq!(runtime.state(), HostRuntimeState::Running);
        runtime.stop().unwrap();
    }
}
