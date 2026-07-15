import AppKit
import SwiftUI

private enum LumenApplicationIcon {
    static func image(size: NSSize) -> NSImage {
        let image = Bundle.main.url(forResource: "lumen", withExtension: "icns")
            .flatMap(NSImage.init(contentsOf:))
            ?? NSWorkspace.shared.icon(forFile: Bundle.main.bundlePath)
        let copy = (image.copy() as? NSImage) ?? image
        copy.size = size
        return copy
    }
}

enum LumenPermissionKind {
    case accessibility
    case screenRecording

    var title: String {
        switch self {
        case .accessibility:
            LumenCopy.Permission.accessibility
        case .screenRecording:
            LumenCopy.Permission.screenRecording
        }
    }

    var detail: String {
        switch self {
        case .accessibility:
            LumenCopy.Permission.accessibilityDragDetail
        case .screenRecording:
            LumenCopy.Permission.screenRecordingDragDetail
        }
    }
}

@MainActor
final class LumenPermissionDragPanelController: NSObject, NSWindowDelegate {
    private var panel: NSPanel?
    private var presentedPermission: LumenPermissionKind?
    private var presentationGeneration: UInt64 = 0

    func present(
        permission: LumenPermissionKind,
        onCheck: @escaping () -> Bool,
        onDragEnded: @escaping () -> Void
    ) {
        presentationGeneration &+= 1
        presentedPermission = permission

        let content = LumenPermissionDragPanel(
            permission: permission,
            onCheck: onCheck,
            onDragEnded: onDragEnded,
            onClose: { [weak self] in self?.close() }
        )
        let hostingController = NSHostingController(rootView: content)
        hostingController.sizingOptions = []

        let panel = panel ?? makePanel()
        panel.title = permission.title
        panel.contentViewController = hostingController
        panel.setContentSize(NSSize(width: 390, height: 300))
        position(panel)
        panel.orderFrontRegardless()
        self.panel = panel
    }

    func update(accessibilityGranted: Bool, screenRecordingGranted: Bool) {
        guard let presentedPermission else {
            return
        }

        let granted = switch presentedPermission {
        case .accessibility: accessibilityGranted
        case .screenRecording: screenRecordingGranted
        }
        if granted {
            let generation = presentationGeneration
            self.presentedPermission = nil
            Task { @MainActor [weak self] in
                await Task.yield()
                guard self?.presentationGeneration == generation else {
                    return
                }
                self?.close()
            }
        }
    }

    func close() {
        presentationGeneration &+= 1
        panel?.close()
        panel = nil
        presentedPermission = nil
    }

    func windowWillClose(_ notification: Notification) {
        panel = nil
        presentedPermission = nil
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 390, height: 300),
            styleMask: [.titled, .closable, .utilityWindow, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.delegate = self
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        return panel
    }

    private func position(_ panel: NSPanel) {
        let mouseLocation = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouseLocation, $0.frame, false) } ?? NSScreen.main
        guard let visibleFrame = screen?.visibleFrame else {
            panel.center()
            return
        }

        let origin = NSPoint(
            x: visibleFrame.maxX - panel.frame.width - 28,
            y: visibleFrame.midY - panel.frame.height / 2
        )
        panel.setFrameOrigin(origin)
    }
}

private struct LumenPermissionDragPanel: View {
    let permission: LumenPermissionKind
    let onCheck: () -> Bool
    let onDragEnded: () -> Void
    let onClose: () -> Void
    @State private var permissionStillRequired = false

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 6) {
                Text(LumenCopy.Permission.dragPanelTitle)
                    .font(.title2.weight(.semibold))
                Text(permission.detail)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            draggableApplication

            if permissionStillRequired {
                Text(LumenCopy.Permission.stillRequired)
                    .font(.caption)
                    .foregroundStyle(.orange)
            } else {
                Label {
                    Text(LumenCopy.Permission.dragHint)
                } icon: {
                    LumenAssetIconView(.drag)
                        .frame(width: 15, height: 15)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            HStack {
                Button(LumenCopy.Action.close, action: onClose)
                Spacer()
                Button(LumenCopy.Action.checkAgain) {
                    permissionStillRequired = !onCheck()
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(22)
        .frame(width: 390, height: 300, alignment: .topLeading)
    }

    private var draggableApplication: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color.accentColor.opacity(0.08))
                .overlay {
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .strokeBorder(Color.accentColor.opacity(0.28), style: StrokeStyle(lineWidth: 1.5, dash: [6, 5]))
                }

            HStack(spacing: 14) {
                Image(nsImage: LumenApplicationIcon.image(size: NSSize(width: 52, height: 52)))
                    .resizable()
                    .frame(width: 52, height: 52)
                VStack(alignment: .leading, spacing: 3) {
                    Text(LumenCopy.productName)
                        .font(.headline)
                    Text(LumenCopy.Permission.dragInstruction)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                LumenAssetIconView(.drag)
                    .frame(width: 22, height: 22)
                    .foregroundStyle(Color.accentColor)
            }
            .padding(.horizontal, 18)
            .allowsHitTesting(false)

            LumenDraggableApplicationView(
                applicationURL: Bundle.main.bundleURL,
                onDragEnded: onDragEnded
            )
        }
        .frame(height: 86)
    }
}

private struct LumenDraggableApplicationView: NSViewRepresentable {
    let applicationURL: URL
    let onDragEnded: () -> Void

    func makeNSView(context: Context) -> LumenApplicationDragSourceView {
        LumenApplicationDragSourceView(
            applicationURL: applicationURL,
            onDragEnded: onDragEnded
        )
    }

    func updateNSView(_ view: LumenApplicationDragSourceView, context: Context) {
        view.applicationURL = applicationURL
        view.onDragEnded = onDragEnded
    }
}

private final class LumenApplicationDragSourceView: NSView, NSDraggingSource {
    var applicationURL: URL
    var onDragEnded: () -> Void

    init(applicationURL: URL, onDragEnded: @escaping () -> Void) {
        self.applicationURL = applicationURL
        self.onDragEnded = onDragEnded
        super.init(frame: .zero)
        setAccessibilityElement(true)
        setAccessibilityLabel(LumenCopy.Permission.dragInstruction)
        setAccessibilityHelp(LumenCopy.Permission.dragAccessibilityHelp)
        setAccessibilityRole(.button)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .openHand)
    }

    override func mouseDown(with event: NSEvent) {
        let applicationIcon = LumenApplicationIcon.image(size: NSSize(width: 64, height: 64))

        let location = convert(event.locationInWindow, from: nil)
        let frame = NSRect(
            x: location.x - 32,
            y: location.y - 32,
            width: 64,
            height: 64
        )
        let item = NSDraggingItem(pasteboardWriter: applicationURL as NSURL)
        item.setDraggingFrame(frame, contents: applicationIcon)

        let session = beginDraggingSession(with: [item], event: event, source: self)
        session.animatesToStartingPositionsOnCancelOrFail = true
    }

    func draggingSession(
        _ session: NSDraggingSession,
        sourceOperationMaskFor context: NSDraggingContext
    ) -> NSDragOperation {
        .copy
    }

    func ignoreModifierKeys(for session: NSDraggingSession) -> Bool {
        true
    }

    func draggingSession(
        _ session: NSDraggingSession,
        endedAt screenPoint: NSPoint,
        operation: NSDragOperation
    ) {
        onDragEnded()
    }
}
