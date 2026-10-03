import SwiftUI

@MainActor
struct KeepAliveView: View {
    @ObservedObject var controller: AppController

    var body: some View {
        Form {
            Section("保活方案") {
                ForEach(controller.keepAliveEntries, id: \.id) { entry in
                    KeepAliveEntryRow(entry: entry, controller: controller)
                }
            }

            if let pipService = controller.pipService {
                Section("画中画来源") {
                    PiPSourceView(service: pipService)
                        .frame(maxWidth: .infinity)
                        .frame(height: 36)
                }
            }

            if let notice = controller.storageNotice {
                Section { Text(notice).font(.caption).foregroundStyle(.secondary) }
            }

            ControllerFeedbackView(controller: controller)
        }
        .navigationTitle("保活")
    }
}

@MainActor
private struct KeepAliveEntryRow: View {
    let entry: KeepAliveEntry
    @ObservedObject var controller: AppController

    private var statusColor: Color {
        entry.state.lastError == nil ? Color.secondary : Color.red
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Toggle(entry.name, isOn: Binding(
                get: { entry.isEnabled },
                set: { controller.setKeepAliveEnabled($0, method: entry.id) }
            ))
            .disabled(!entry.isEnabled &&
                      (entry.state.phase == .stopping || entry.isTransitioning))

            HStack(spacing: 6) {
                if entry.isTransitioning { ProgressView().controlSize(.small) }
                Text(entry.state.description)
                    .font(.caption)
                    .foregroundStyle(statusColor)
            }
            if let error = entry.state.lastError {
                Text(error).font(.caption).foregroundStyle(Color.red).textSelection(.enabled)
            }
        }
    }
}
