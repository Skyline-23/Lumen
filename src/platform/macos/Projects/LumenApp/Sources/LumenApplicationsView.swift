import LumenMacBridge
import SwiftUI

struct LumenApplicationsView: View {
    @ObservedObject var controller: LumenCaptureController
    @State private var editedApplication: LumenApplication?

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                pageHeader(LumenCopy.Navigation.applications, subtitle: LumenCopy.Applications.subtitle)
                Spacer()
                if controller.isApplicationOperationInFlight {
                    ProgressView().controlSize(.small)
                }
                Button {
                    editedApplication = LumenApplication(name: LumenCopy.Applications.newApplication)
                } label: {
                    Label {
                        Text(LumenCopy.Action.add)
                    } icon: {
                        LumenAssetIconView(.add)
                            .frame(width: 16, height: 16)
                    }
                }
                .buttonStyle(.borderedProminent)
            }
            .padding(28)

            Divider()

            if controller.applications.isEmpty && !controller.isApplicationOperationInFlight {
                ContentUnavailableView {
                    Label {
                        Text(LumenCopy.Applications.emptyTitle)
                    } icon: {
                        LumenAssetIconView(.applications)
                    }
                } description: {
                    Text(LumenCopy.Applications.emptyDetail)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    ForEach(controller.applications) { application in
                        applicationRow(application)
                    }
                    .onMove(perform: controller.moveApplications)
                }
                .listStyle(.inset)
            }
        }
        .task {
            controller.refreshApplications()
        }
        .sheet(item: $editedApplication) { application in
            LumenApplicationEditor(application: application) { updated in
                controller.saveApplication(updated)
            }
        }
    }

    private func applicationRow(_ application: LumenApplication) -> some View {
        HStack(spacing: 13) {
            LumenAssetIconView(
                application.command.isEmpty && application.detachedCommands.isEmpty ? .desktop : .application
            )
                .frame(width: 22, height: 22)
                .foregroundStyle(.secondary)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 3) {
                Text(application.name)
                    .font(.body.weight(.medium))
                Text(
                    application.command.isEmpty
                        ? application.detachedCommands.first ?? LumenCopy.Applications.streamDesktop
                        : application.command
                )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            if application.virtualDisplay {
                Label {
                    Text(LumenCopy.Applications.virtualDisplay)
                } icon: {
                    LumenAssetIconView(.virtualDisplay)
                        .frame(width: 14, height: 14)
                }
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Button(LumenCopy.Action.edit) {
                editedApplication = application
            }
            .buttonStyle(.borderless)
            Button(role: .destructive) {
                controller.deleteApplication(application)
            } label: {
                LumenAssetIconView(.delete)
                    .frame(width: 16, height: 16)
            }
            .buttonStyle(.borderless)
            .disabled(controller.isApplicationOperationInFlight)
        }
        .padding(.vertical, 7)
        .contextMenu {
            Button(LumenCopy.Action.edit) { editedApplication = application }
            Button(LumenCopy.Action.delete, role: .destructive) { controller.deleteApplication(application) }
        }
    }
}
struct LumenApplicationEditor: View {
    @Environment(\.dismiss) private var dismiss
    @State private var application: LumenApplication
    let onSave: (LumenApplication) -> Void

    init(application: LumenApplication, onSave: @escaping (LumenApplication) -> Void) {
        _application = State(initialValue: application)
        self.onSave = onSave
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(
                    application.id.isEmpty
                        ? LumenCopy.Applications.addTitle
                        : LumenCopy.Applications.editTitle
                )
                    .font(.title2.weight(.semibold))
                Spacer()
            }
            .padding(22)
            Divider()
            Form {
                Section(LumenCopy.Applications.identity) {
                    TextField(LumenCopy.Applications.name, text: $application.name)
                    TextField(LumenCopy.Applications.coverPath, text: $application.imagePath)
                }
                Section(LumenCopy.Applications.launch) {
                    TextField(LumenCopy.Applications.command, text: $application.command)
                    TextField(LumenCopy.Applications.workingDirectory, text: $application.workingDirectory)
                    TextField(
                        LumenCopy.Applications.detachedCommands,
                        text: stringListBinding(\.detachedCommands)
                    )
                    Stepper(
                        LumenCopy.Applications.exitTimeout(seconds: application.exitTimeout),
                        value: $application.exitTimeout,
                        in: 0...60
                    )
                }
                Section(LumenCopy.Applications.display) {
                    Toggle(LumenCopy.Applications.createVirtualDisplay, isOn: $application.virtualDisplay)
                    Stepper(
                        LumenCopy.Applications.desktopScale(percent: application.scaleFactor),
                        value: $application.scaleFactor,
                        in: 50...300,
                        step: 5
                    )
                }
                Section(LumenCopy.Applications.processBehavior) {
                    Toggle(LumenCopy.Applications.detachAutomatically, isOn: $application.autoDetach)
                    Toggle(LumenCopy.Applications.waitForAllProcesses, isOn: $application.waitForAllProcesses)
                    Toggle(LumenCopy.Applications.terminateWhenPaused, isOn: $application.terminateOnPause)
                    Toggle(LumenCopy.Applications.runElevated, isOn: $application.elevated)
                }
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)
            Divider()
            HStack {
                Spacer()
                Button(LumenCopy.Action.cancel) { dismiss() }
                Button(LumenCopy.Action.save) {
                    onSave(application)
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .disabled(application.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .padding(18)
        }
        .frame(width: 590, height: 650)
    }

    private func stringListBinding(_ keyPath: WritableKeyPath<LumenApplication, [String]>) -> Binding<String> {
        Binding(
            get: { application[keyPath: keyPath].joined(separator: "\n") },
            set: { value in
                application[keyPath: keyPath] = value
                    .split(separator: "\n")
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                    .filter { !$0.isEmpty }
            }
        )
    }
}
