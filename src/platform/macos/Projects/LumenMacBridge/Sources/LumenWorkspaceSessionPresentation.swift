import CoreGraphics
import Foundation

enum LumenMacPointerPositioner {
    static func centerPoint(geometry: LumenMacDisplayGeometry) -> CGPoint {
        CGPoint(
            x: CGFloat(geometry.logicalWidth) / 2,
            y: CGFloat(geometry.logicalHeight) / 2
        )
    }

    static func centerPointer(
        on displayID: CGDirectDisplayID,
        geometry: LumenMacDisplayGeometry
    ) {
        let result = CGDisplayMoveCursorToPoint(displayID, centerPoint(geometry: geometry))
        guard result != .success else {
            return
        }
        let message =
            "Lumen pointer initialization failed " +
            "display-id=\(displayID) status=\(result.rawValue)\n"
        FileHandle.standardError.write(Data(message.utf8))
    }
}

enum LumenWorkspaceEventPublisher {
    private struct Event {
        let disposition: Int
        let severity: Int
        let code: Int
        let body: String
    }

    private static let notification = Notification.Name("LumenRuntimeEventNotification")
    private static let isolationWarningCode = 13

    static func publish(_ status: LumenMacWorkspaceIsolationStatus) {
        guard let event = makeEvent(for: status) else {
            return
        }
        DistributedNotificationCenter.default().postNotificationName(
            notification,
            object: nil,
            userInfo: [
                "identifier": "runtime-event-\(event.code)",
                "disposition": event.disposition,
                "severity": event.severity,
                "code": event.code,
                "body": event.body,
                "launchPath": "/diagnostics"
            ],
            deliverImmediately: true
        )
    }

    private static func makeEvent(
        for status: LumenMacWorkspaceIsolationStatus
    ) -> Event? {
        switch status {
        case .notRequested, .applied:
            return Event(
                disposition: 1,
                severity: 0,
                code: isolationWarningCode,
                body: ""
            )
        case .pending:
            return nil
        case .unavailable(let message):
            return Event(
                disposition: 0,
                severity: 0,
                code: isolationWarningCode,
                body: message
            )
        case .failed(let message):
            return Event(
                disposition: 0,
                severity: 1,
                code: 6,
                body: message
            )
        }
    }
}
