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

    var dragTitle: String {
        switch self {
        case .accessibility:
            LumenCopy.Permission.accessibilityDragTitle
        case .screenRecording:
            LumenCopy.Permission.screenRecordingDragTitle
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
        panel.setContentSize(NSSize(width: 430, height: 324))
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
            contentRect: NSRect(x: 0, y: 0, width: 430, height: 324),
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
        panel.isOpaque = false
        panel.backgroundColor = .clear
        return panel
    }

    private func position(_ panel: NSPanel) {
        let mouseLocation = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouseLocation, $0.frame, false) } ?? NSScreen.main
        guard let visibleFrame = screen?.visibleFrame else {
            panel.center()
            return
        }

        let margin: CGFloat = 18
        let availableSize = NSSize(
            width: max(1, visibleFrame.width - margin * 2),
            height: max(1, visibleFrame.height - margin * 2)
        )
        if panel.frame.width > availableSize.width || panel.frame.height > availableSize.height {
            let availableContentSize = panel.contentRect(
                forFrameRect: NSRect(origin: .zero, size: availableSize)
            ).size
            panel.setContentSize(
                NSSize(
                    width: min(430, availableContentSize.width),
                    height: min(324, availableContentSize.height)
                )
            )
        }
        let maxOriginX = visibleFrame.maxX - panel.frame.width - margin
        let maxOriginY = visibleFrame.maxY - panel.frame.height - margin
        let origin = NSPoint(
            x: min(max(visibleFrame.minX + margin, visibleFrame.maxX - panel.frame.width - 28), maxOriginX),
            y: min(max(visibleFrame.minY + margin, visibleFrame.midY - panel.frame.height / 2), maxOriginY)
        )
        panel.setFrameOrigin(origin)
    }
}

private struct LumenPermissionDragPanel: View {
    let permission: LumenPermissionKind
    let onCheck: () -> Bool
    let onDragEnded: () -> Void
    let onClose: () -> Void
    @Environment(\.colorScheme) private var colorScheme
    @State private var permissionStillRequired = false

    var body: some View {
        ZStack {
            background

            VStack(alignment: .leading, spacing: 14) {
                header
                draggableApplication
                status
                footer
            }
            .padding(24)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .strokeBorder(borderColor, lineWidth: 1)
        }
        .tint(mintAccent)
        .preferredColorScheme(colorScheme)
    }

    private var background: some View {
        LinearGradient(
            colors: colorScheme == .dark
                ? [
                    Color(red: 0.025, green: 0.105, blue: 0.17),
                    Color(red: 0.055, green: 0.19, blue: 0.22),
                    Color(red: 0.055, green: 0.13, blue: 0.13)
                ]
                : [
                    Color(red: 0.88, green: 0.95, blue: 0.97),
                    Color(red: 0.86, green: 0.96, blue: 0.92),
                    Color(red: 0.98, green: 0.96, blue: 0.88)
                ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
        .overlay {
            RadialGradient(
                colors: [palette.mintGlow.opacity(colorScheme == .dark ? 1.0 : 0.9), .clear],
                center: .topTrailing,
                startRadius: 0,
                endRadius: 280
            )
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(permission.dragTitle)
                .font(.title2.weight(.bold))
                .foregroundStyle(primaryText)
                .lineLimit(1)
            Text(LumenCopy.Permission.dragPanelDetail)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(secondaryText)
                .fixedSize(horizontal: false, vertical: true)
                .lineLimit(2)
        }
    }

    @ViewBuilder
    private var status: some View {
        HStack(spacing: 9) {
            LumenAssetIconView(permissionStillRequired ? .attention : .drag)
                .frame(width: 18, height: 18)
                .foregroundStyle(permissionStillRequired ? Color.orange : mintAccent)
            Text(permissionStillRequired ? LumenCopy.Permission.notEnabled : LumenCopy.Permission.dragHint)
                .font(.caption.weight(.semibold))
                .foregroundStyle(permissionStillRequired ? Color.orange : secondaryText)
                .fixedSize(horizontal: false, vertical: true)
                .lineLimit(2)
        }
    }

    private var footer: some View {
        HStack(spacing: 12) {
            Button(LumenCopy.Action.close, action: onClose)
                .buttonStyle(.plain)
                .font(.body.weight(.semibold))
                .foregroundStyle(primaryText)
            Spacer(minLength: 8)
            Button(LumenCopy.Action.checkAgain) {
                permissionStillRequired = !onCheck()
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
        }
    }

    private var primaryText: Color {
        palette.primaryText
    }

    private var secondaryText: Color {
        palette.secondaryText
    }

    private var borderColor: Color {
        colorScheme == .dark ? mintAccent.opacity(0.42) : Color.black.opacity(0.16)
    }

    private var mintAccent: Color {
        colorScheme == .dark
            ? Color(red: 0.31, green: 0.86, blue: 0.78)
            : Color(red: 0.05, green: 0.56, blue: 0.48)
    }

    private var palette: LumenAuthenticationPalette {
        LumenAuthenticationPalette(colorScheme: colorScheme)
    }

    private var draggableApplication: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(mintAccent.opacity(colorScheme == .dark ? 0.10 : 0.08))
                .overlay {
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .strokeBorder(
                            mintAccent.opacity(colorScheme == .dark ? 0.52 : 0.42),
                            style: StrokeStyle(lineWidth: 1.5, dash: [7, 5])
                        )
                }

            HStack(spacing: 15) {
                Image(nsImage: LumenApplicationIcon.image(size: NSSize(width: 58, height: 58)))
                    .resizable()
                    .frame(width: 58, height: 58)
                    .clipShape(RoundedRectangle(cornerRadius: 15, style: .continuous))
                VStack(alignment: .leading, spacing: 3) {
                    Text(LumenCopy.productName)
                        .font(.headline.weight(.bold))
                        .foregroundStyle(primaryText)
                    Text(LumenCopy.Permission.dragInstruction)
                        .font(.caption)
                        .foregroundStyle(secondaryText)
                }
                Spacer()
                LumenAssetIconView(.drag)
                    .frame(width: 24, height: 24)
                    .foregroundStyle(mintAccent)
            }
            .padding(.horizontal, 20)
            .allowsHitTesting(false)

            LumenDraggableApplicationView(
                applicationURL: Bundle.main.bundleURL,
                onDragEnded: onDragEnded
            )
        }
        .frame(height: 88)
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
