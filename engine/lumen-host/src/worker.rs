use std::fmt;

use crate::{
    HostArguments, HostCommand, HostRuntime, HostRuntimeError, HostRuntimeState, HostService,
};

pub trait HostCommandSource {
    fn next_command(&mut self) -> Result<HostCommand, String>;
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub enum WorkerRunError {
    Runtime(HostRuntimeError),
    CommandSource(String),
    RuntimeAndCleanup {
        runtime: HostRuntimeError,
        cleanup: HostRuntimeError,
    },
    CommandSourceAndCleanup {
        source: String,
        cleanup: HostRuntimeError,
    },
}

impl fmt::Display for WorkerRunError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::Runtime(error) => write!(formatter, "worker runtime failed: {error}"),
            Self::CommandSource(error) => {
                write!(formatter, "worker command source failed: {error}")
            }
            Self::RuntimeAndCleanup { runtime, cleanup } => write!(
                formatter,
                "worker runtime failed: {runtime}; cleanup also failed: {cleanup}"
            ),
            Self::CommandSourceAndCleanup { source, cleanup } => write!(
                formatter,
                "worker command source failed: {source}; cleanup also failed: {cleanup}"
            ),
        }
    }
}

impl std::error::Error for WorkerRunError {}

pub fn run_worker<Service, Source>(
    arguments: &HostArguments,
    runtime: &mut HostRuntime<Service>,
    source: &mut Source,
) -> Result<(), WorkerRunError>
where
    Service: HostService,
    Source: HostCommandSource,
{
    runtime.start(arguments).map_err(WorkerRunError::Runtime)?;
    loop {
        let command = match source.next_command() {
            Ok(command) => command,
            Err(source_error) => {
                return match cleanup_running(runtime) {
                    Ok(()) => Err(WorkerRunError::CommandSource(source_error)),
                    Err(cleanup) => Err(WorkerRunError::CommandSourceAndCleanup {
                        source: source_error,
                        cleanup,
                    }),
                }
            }
        };
        if let Err(runtime_error) = runtime.handle(command) {
            return match cleanup_running(runtime) {
                Ok(()) => Err(WorkerRunError::Runtime(runtime_error)),
                Err(cleanup) => Err(WorkerRunError::RuntimeAndCleanup {
                    runtime: runtime_error,
                    cleanup,
                }),
            };
        }
        if runtime.state() == HostRuntimeState::Stopped {
            return Ok(());
        }
    }
}

fn cleanup_running<Service: HostService>(
    runtime: &mut HostRuntime<Service>,
) -> Result<(), HostRuntimeError> {
    if runtime.state() == HostRuntimeState::Running {
        runtime.stop()
    } else {
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use std::collections::VecDeque;

    use super::*;

    #[derive(Default)]
    struct RecordingService {
        events: Vec<&'static str>,
        fail_force_stop: bool,
    }

    impl HostService for RecordingService {
        fn start(&mut self, _arguments: &HostArguments) -> Result<(), String> {
            self.events.push("start");
            Ok(())
        }

        fn force_stop_stream(&mut self) -> Result<(), String> {
            self.events.push("force-stop");
            if self.fail_force_stop {
                Err("force stop failed".into())
            } else {
                Ok(())
            }
        }

        fn reload_applications(&mut self) -> Result<(), String> {
            self.events.push("reload");
            Ok(())
        }

        fn stop(&mut self) -> Result<(), String> {
            self.events.push("stop");
            Ok(())
        }
    }

    struct Commands(VecDeque<Result<HostCommand, String>>);

    impl HostCommandSource for Commands {
        fn next_command(&mut self) -> Result<HostCommand, String> {
            self.0
                .pop_front()
                .unwrap_or_else(|| Err("command source exhausted".into()))
        }
    }

    fn arguments() -> HostArguments {
        crate::config::tests::valid_arguments_for_runtime_tests()
    }

    #[test]
    fn runs_signal_equivalent_commands_until_shutdown() {
        let mut runtime = HostRuntime::new(RecordingService::default());
        let mut commands = Commands(VecDeque::from([
            Ok(HostCommand::ForceStopStream),
            Ok(HostCommand::ReloadApplications),
            Ok(HostCommand::Restart),
        ]));
        run_worker(&arguments(), &mut runtime, &mut commands).unwrap();
        assert_eq!(
            runtime.service().events,
            ["start", "force-stop", "reload", "stop"]
        );
        assert_eq!(runtime.state(), HostRuntimeState::Stopped);
    }

    #[test]
    fn command_failure_still_runs_service_cleanup() {
        let mut runtime = HostRuntime::new(RecordingService {
            fail_force_stop: true,
            ..RecordingService::default()
        });
        let mut commands = Commands(VecDeque::from([Ok(HostCommand::ForceStopStream)]));
        assert!(matches!(
            run_worker(&arguments(), &mut runtime, &mut commands),
            Err(WorkerRunError::Runtime(HostRuntimeError::Service {
                operation: "force-stop-stream",
                ..
            }))
        ));
        assert_eq!(runtime.service().events, ["start", "force-stop", "stop"]);
        assert_eq!(runtime.state(), HostRuntimeState::Stopped);
    }

    #[test]
    fn command_source_failure_still_runs_service_cleanup() {
        let mut runtime = HostRuntime::new(RecordingService::default());
        let mut commands = Commands(VecDeque::from([Err("signal wait failed".into())]));
        assert_eq!(
            run_worker(&arguments(), &mut runtime, &mut commands),
            Err(WorkerRunError::CommandSource("signal wait failed".into()))
        );
        assert_eq!(runtime.service().events, ["start", "stop"]);
    }
}
