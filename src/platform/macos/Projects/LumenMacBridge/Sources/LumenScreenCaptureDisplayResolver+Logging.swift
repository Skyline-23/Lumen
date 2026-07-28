import OSLog

extension LumenScreenCaptureDisplayResolver {
    private static let logger = Logger(
        subsystem: "dev.skyline23.lumen",
        category: "ScreenCaptureStartup"
    )

    static func logQueryStart(displayID: UInt32, generation: UInt64) {
        writeQueryDiagnostic(
            stage: "display-query-generation-start",
            displayID: displayID,
            generation: generation,
            isWarning: false
        )
    }

    static func logQueryTimeout(displayID: UInt32, generation: UInt64) {
        writeQueryDiagnostic(
            stage: "display-query-timeout",
            displayID: displayID,
            generation: generation,
            isWarning: true
        )
    }

    static func logLateQueryResultAvailable(
        displayID: UInt32,
        generation: UInt64
    ) {
        writeQueryDiagnostic(
            stage: "display-query-late-result-available",
            displayID: displayID,
            generation: generation,
            isWarning: false
        )
    }

    static func logCompletedQueryAdopted(
        displayID: UInt32,
        generation: UInt64
    ) {
        writeQueryDiagnostic(
            stage: "display-query-completed-result-adopted",
            displayID: displayID,
            generation: generation,
            isWarning: false
        )
    }

    static func logLateQueryResultDiscarded(
        displayID: UInt32,
        generation: UInt64
    ) {
        writeQueryDiagnostic(
            stage: "display-query-late-result-discarded",
            displayID: displayID,
            generation: generation,
            isWarning: true
        )
    }

    private static func writeQueryDiagnostic(
        stage: String,
        displayID: UInt32,
        generation: UInt64,
        isWarning: Bool
    ) {
        let message = [
            "stage=\(stage)",
            "display-id=\(displayID)",
            "generation=\(generation)"
        ].joined(separator: " ")
        if isWarning {
            logger.warning("\(message, privacy: .public)")
        } else {
            logger.notice("\(message, privacy: .public)")
        }
        writeScreenCaptureStartupDiagnostic(message)
    }
}
