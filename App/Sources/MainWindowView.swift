import SwiftUI
import LogRollerCore
import AppKit

struct MainWindowView: View {
    @Bindable var model: AppModel

    var body: some View {
        NavigationSplitView {
            RunSidebarView(model: model)
        } detail: {
            RunDetailView(model: model)
        }
    }
}

private struct RunSidebarView: View {
    @Bindable var model: AppModel
    @State private var runPendingDeletion: RunSummary?

    var body: some View {
        List(selection: Binding(get: {
            model.selectedRunID
        }, set: { selection in
            Task {
                await model.setSelectedRun(selection)
            }
        })) {
            ForEach(model.runSummaries) { run in
                VStack(alignment: .leading) {
                    Text(run.runID)
                        .bold()
                    Text("\(run.eventCount) events • \(run.deviceCount) devices")
                        .font(.caption)
                }
                .tag(run.runID)
                .contextMenu {
                    Button("Delete Run", role: .destructive) {
                        runPendingDeletion = run
                    }
                }
            }
        }
        .overlay {
            if model.runSummaries.isEmpty {
                ContentUnavailableView(
                    "No Runs Yet",
                    systemImage: "tray",
                    description: Text("Click Simulate Ingest to create test data.")
                )
            }
        }
        .navigationTitle("Runs")
        .toolbar {
            ToolbarItem {
                Button("Refresh") {
                    Task {
                        await model.refreshRuns()
                    }
                }
            }
            ToolbarItem {
                Button("Delete Run", systemImage: "trash", role: .destructive) {
                    guard let selectedRunID = model.selectedRunID,
                          let selectedRun = model.runSummaries.first(where: { $0.runID == selectedRunID }) else {
                        return
                    }
                    runPendingDeletion = selectedRun
                }
                .disabled(model.selectedRunID == nil)
            }
        }
        .alert(
            "Delete Run?",
            isPresented: Binding(
                get: { runPendingDeletion != nil },
                set: { show in
                    if !show {
                        runPendingDeletion = nil
                    }
                }
            ),
            presenting: runPendingDeletion
        ) { run in
            Button("Delete", role: .destructive) {
                let runID = run.runID
                runPendingDeletion = nil
                Task {
                    await model.deleteRun(runID)
                }
            }
            Button("Cancel", role: .cancel) {
                runPendingDeletion = nil
            }
        } message: { run in
            Text("This permanently removes \(run.runID) and all of its stored device event data.")
        }
    }
}

private struct RunDetailView: View {
    @Bindable var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ServerControlBar(model: model)
            DevicePicker(model: model)
            HStack {
                Text("Events")
                    .font(.headline)
                Spacer()
                Text("\(model.selectedEvents.count)")
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal)
            .padding(.top, 8)
            EventList(model: model)
            if let lastErrorMessage = model.lastErrorMessage {
                Text(lastErrorMessage)
                    .font(.footnote)
                    .foregroundStyle(.red)
                    .padding(.horizontal)
                    .padding(.vertical, 8)
            }
        }
        .navigationTitle(model.selectedRunID ?? "LogRoller")
    }
}

private struct ServerControlBar: View {
    @Bindable var model: AppModel

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading) {
                Text("Server")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if model.serverStatus.isRunning {
                    HStack(spacing: 6) {
                        Text(verbatim: model.primaryIngestBaseURL ?? "Running")
                            .textSelection(.enabled)
                            .lineLimit(2)
                            .minimumScaleFactor(0.9)

                        if let url = model.primaryIngestBaseURL {
                            Button {
                                copyToPasteboard(url)
                            } label: {
                                Image(systemName: "doc.on.doc")
                            }
                            .buttonStyle(.borderless)
                            .help("Copy URL")
                        }
                    }
                } else {
                    Text("Stopped")
                }
            }

            Spacer(minLength: 12)

            HStack {
                Button("Simulate Ingest") {
                    Task {
                        await model.simulateIngest()
                    }
                }
            }
            .buttonStyle(.bordered)
        }
        .padding(.vertical, 10)
        .padding(.horizontal, 12)
        .background(.quinary)
        .clipShape(.rect(cornerRadius: 10))
        .padding([.top, .horizontal])
    }

    private func copyToPasteboard(_ value: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value, forType: .string)
    }
}

private struct DevicePicker: View {
    @Bindable var model: AppModel

    var body: some View {
        Picker("Device", selection: Binding(get: {
            model.selectedDeviceID ?? "all"
        }, set: { next in
            Task {
                await model.setSelectedDevice(next == "all" ? nil : next)
            }
        })) {
            Text("All Devices").tag("all")
            ForEach(model.deviceSummaries) { summary in
                Text("\(summary.deviceID) (\(summary.eventCount))").tag(summary.deviceID)
            }
        }
        .padding(.horizontal)
        .disabled(model.selectedRunID == nil)
    }
}

private struct EventList: View {
    @Bindable var model: AppModel

    var body: some View {
        if model.selectedRunID == nil {
            ContentUnavailableView(
                "Select a Run",
                systemImage: "sidebar.left",
                description: Text("Choose a run from the sidebar to view event details.")
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if model.selectedEvents.isEmpty {
            ContentUnavailableView(
                "No Events Found",
                systemImage: "list.bullet.rectangle",
                description: Text("No events are available for the selected run/device filter.")
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            List(model.selectedEvents) { event in
                VStack(alignment: .leading, spacing: 4) {
                    Text(event.event)
                        .bold()
                    Text("\(event.deviceID) • \(event.level.rawValue) • \(sequenceLabel(for: event))")
                        .font(.caption)
                    Text("event: \(LogRollerJSONCoders.render(date: event.ts))")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Text("received: \(LogRollerJSONCoders.render(date: event.recvTS))")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Text(payloadString(for: event.payload))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .lineLimit(3)
                }
            }
        }
    }

    private func sequenceLabel(for event: StoredEvent) -> String {
        guard let seq = event.seq else {
            return "seq unknown"
        }
        return "seq \(seq)"
    }

    private func payloadString(for payload: JSONValue) -> String {
        guard let data = try? LogRollerJSONCoders.encoder.encode(payload),
              let text = String(data: data, encoding: .utf8) else {
            return "payload unavailable"
        }
        return "payload: \(text)"
    }
}
