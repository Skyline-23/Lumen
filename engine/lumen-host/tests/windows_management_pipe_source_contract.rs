const PIPE: &str = include_str!("../src/platform/windows/native_management_pipe.rs");
const CLIENT: &str = include_str!("../../../src/platform/windows/Lumen.App/LumenControlClient.cs");

#[test]
fn connected_idle_client_cannot_leave_the_server_in_a_blocking_read() {
    // The Windows implementation is not compiled on non-Windows CI, so keep a
    // source-level contract around the platform wiring in addition to the
    // cross-platform dispatcher tests in windows_management.rs.
    let server = PIPE
        .split("fn run_server")
        .nth(1)
        .expect("Windows management server implementation")
        .split("fn client_is_in_agent_session")
        .next()
        .expect("bounded Windows management server implementation");
    let create_pipe = PIPE
        .split("fn create_pipe")
        .nth(1)
        .expect("Windows management pipe creation")
        .split("fn connect_client")
        .next()
        .expect("bounded Windows management pipe creation");
    let read = PIPE
        .split("fn read_request")
        .nth(1)
        .expect("Windows management request read")
        .split("fn write_response")
        .next()
        .expect("bounded Windows management request read");
    let wait = PIPE
        .split("fn wait_for_overlapped")
        .nth(1)
        .expect("Windows management overlapped wait")
        .split("fn cancel_overlapped")
        .next()
        .expect("bounded Windows management overlapped wait");
    let cancel_source = PIPE
        .split("fn cancel_overlapped")
        .nth(1)
        .expect("Windows management overlapped cancellation")
        .split("fn create_event")
        .next()
        .expect("bounded Windows management overlapped cancellation");
    let acknowledgement = PIPE
        .split("fn read_response_ack")
        .nth(1)
        .expect("Windows management response acknowledgement")
        .split("fn wait_for_overlapped")
        .next()
        .expect("bounded Windows management response acknowledgement");
    let shutdown = PIPE
        .split("fn stop_server_thread")
        .nth(1)
        .expect("Windows management shutdown implementation")
        .split("struct NativeCommands")
        .next()
        .expect("bounded Windows management shutdown implementation");

    let deadline = shutdown
        .find("Instant::now() + THREAD_STOP_TIMEOUT")
        .expect("bounded cancellation deadline");
    let shutdown_cancel = shutdown
        .find("CancelSynchronousIo(thread.as_raw_handle() as HANDLE)")
        .expect("synchronous pipe I/O cancellation");
    let join_gate = shutdown
        .find("if thread.is_finished()")
        .expect("non-blocking join gate");

    assert!(create_pipe.contains("PIPE_ACCESS_DUPLEX | FILE_FLAG_OVERLAPPED"));
    assert!(read.contains("&mut overlapped"));
    assert!(read.contains("CLIENT_IO_TIMEOUT"));
    assert!(!read.contains("null_mut(),\n        )"));
    assert!(wait.contains("Instant::now() >= deadline"));
    assert!(wait.contains("cancel_overlapped(pipe, overlapped)"));
    assert!(cancel_source.contains("CancelIoEx(pipe, overlapped)"));
    assert!(cancel_source.contains("GetOverlappedResult(pipe, overlapped, &mut ignored, 1)"));
    assert!(acknowledgement.contains("RESPONSE_ACK"));
    assert!(acknowledgement.contains("&mut overlapped"));
    assert!(acknowledgement.contains("CLIENT_IO_TIMEOUT"));
    assert!(!PIPE.contains("FlushFileBuffers"));
    assert!(!PIPE.contains("OpenThread"));
    let response_write = server
        .find("write_response(pipe.get(), &response, &stop)")
        .expect("overlapped response write");
    let response_ack = server
        .find("read_response_ack(pipe.get(), &stop)")
        .expect("bounded response acknowledgement");
    let disconnect = response_ack
        + server[response_ack..]
            .find("DisconnectNamedPipe(pipe.get())")
            .expect("pipe disconnect");
    assert!(response_write < response_ack);
    assert!(response_ack < disconnect);
    assert!(deadline < shutdown_cancel);
    assert!(shutdown_cancel < join_gate);
    assert!(shutdown.contains("Instant::now() < deadline"));
    assert!(shutdown.contains("wake_server()"));
    assert!(shutdown.contains("THREAD_STOP_POLL_INTERVAL"));
    assert!(
        !shutdown.contains("thread.join().is_err()")
            || join_gate < shutdown.find("thread.join().is_err()").unwrap()
    );
}

#[test]
fn native_client_acknowledges_the_complete_message_before_deserializing() {
    let message_complete = CLIENT
        .find("while (!pipe.IsMessageComplete)")
        .expect("message-mode response completion");
    let acknowledgement = CLIENT
        .find("pipe.WriteAsync(ResponseAck, cancellationToken)")
        .expect("response acknowledgement write");
    let deserialize = CLIENT
        .find("JsonSerializer.Deserialize<ManagementEnvelope>")
        .expect("management response deserialization");

    assert!(CLIENT.contains("pipe.ReadMode = PipeTransmissionMode.Message"));
    assert!(CLIENT.contains("ResponseAck = [0x06]"));
    assert!(message_complete < acknowledgement);
    assert!(acknowledgement < deserialize);
}
