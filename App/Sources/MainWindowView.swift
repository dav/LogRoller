import SwiftUI
import LogRollerCore
import AppKit

private func copyToPasteboard(_ value: String) {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(value, forType: .string)
}

private func payloadJSONString(for payload: JSONValue) -> String {
    guard let data = try? LogRollerJSONCoders.encoder.encode(payload),
          let text = String(data: data, encoding: .utf8) else {
        return "payload unavailable"
    }
    return text
}

private let localTimestampFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.dateFormat = "yyyy-MM-dd hh:mm:ss a"
    return formatter
}()

private func localTimestampString(for date: Date) -> String {
    localTimestampFormatter.string(from: date)
}

private func eventJSONString(for event: StoredEvent) -> String? {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    encoder.dateEncodingStrategy = .custom { value, encoder in
        var container = encoder.singleValueContainer()
        try container.encode(LogRollerJSONCoders.render(date: value))
    }
    guard let data = try? encoder.encode(event) else { return nil }
    return String(data: data, encoding: .utf8)
}

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
    @State private var runIDsPendingDeletion: Set<String> = []

    private var isShowingDeleteConfirmation: Binding<Bool> {
        Binding(
            get: { !runIDsPendingDeletion.isEmpty },
            set: { show in
                if !show {
                    runIDsPendingDeletion = []
                }
            }
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            RunFilterField(text: $model.runFilterText)
            List(selection: Binding(get: {
                model.selectedRunIDs
            }, set: { selection in
                Task {
                    await model.setSelectedRuns(selection)
                }
            })) {
                ForEach(model.filteredRunSummaries) { run in
                    VStack(alignment: .leading) {
                        Text(run.runID)
                            .bold()
                        Text("\(run.eventCount) events • \(run.deviceCount) devices")
                            .font(.caption)
                    }
                    .tag(run.runID)
                }
            }
            .contextMenu(forSelectionType: String.self) { runIDs in
                if !runIDs.isEmpty {
                    Button(deleteButtonTitle(for: runIDs.count), role: .destructive) {
                        runIDsPendingDeletion = runIDs
                    }
                }
            }
            .overlay {
                if model.filteredRunSummaries.isEmpty {
                    if model.runSummaries.isEmpty {
                        ContentUnavailableView(
                            "No Runs Yet",
                            systemImage: "tray",
                            description: Text("Click Simulate Ingest to create test data.")
                        )
                    } else {
                        ContentUnavailableView(
                            "No Matching Runs",
                            systemImage: "magnifyingglass",
                            description: Text("Adjust the filter to show matching run IDs.")
                        )
                    }
                }
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
                Button(deleteButtonTitle(for: model.selectedRunIDs.count), systemImage: "trash", role: .destructive) {
                    guard !model.selectedRunIDs.isEmpty else { return }
                    runIDsPendingDeletion = model.selectedRunIDs
                }
                .disabled(model.selectedRunIDs.isEmpty)
            }
        }
        .alert(
            deleteAlertTitle(for: runIDsPendingDeletion.count),
            isPresented: isShowingDeleteConfirmation
        ) {
            Button("Delete", role: .destructive) {
                let runIDs = runIDsPendingDeletion
                runIDsPendingDeletion = []
                Task {
                    await model.deleteRuns(runIDs)
                }
            }
            Button("Cancel", role: .cancel) {
                runIDsPendingDeletion = []
            }
        } message: {
            Text(deleteAlertMessage(for: runIDsPendingDeletion))
        }
    }

    private func deleteButtonTitle(for count: Int) -> String {
        count <= 1 ? "Delete Run" : "Delete \(count) Runs"
    }

    private func deleteAlertTitle(for count: Int) -> String {
        count <= 1 ? "Delete Run?" : "Delete \(count) Runs?"
    }

    private func deleteAlertMessage(for runIDs: Set<String>) -> String {
        if runIDs.count == 1, let runID = runIDs.first {
            return "This permanently removes \(runID) and all of its stored device event data."
        }
        return "This permanently removes \(runIDs.count) runs and all of their stored device event data."
    }
}

private struct RunDetailView: View {
    @Bindable var model: AppModel
    @State private var filterText: String = ""

    var body: some View {
        let filteredEvents = filteredEvents(for: filterText)
        VStack(alignment: .leading, spacing: 0) {
            ServerControlBar(model: model)
            DevicePicker(model: model)
            EventFilterField(text: $filterText)
            HStack {
                Text("Events")
                    .font(.headline)
                Text("(max 500 of most recent)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Text("\(filteredEvents.count)")
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal)
            .padding(.top, 8)
            EventList(model: model, events: filteredEvents, filterText: filterText)
            if let lastErrorMessage = model.lastErrorMessage {
                Text(lastErrorMessage)
                    .font(.footnote)
                    .foregroundStyle(.red)
                    .padding(.horizontal)
                    .padding(.vertical, 8)
            }
        }
        .navigationTitle(model.selectedRunID ?? "LogRoller")
        .toolbar {
            if let runID = model.selectedRunID {
                ToolbarItem(placement: .principal) {
                    Button {
                        copyToPasteboard(runID)
                    } label: {
                        Image(systemName: "doc.on.doc")
                    }
                    .buttonStyle(.borderless)
                    .help("Copy run ID")
                }
            }
        }
    }

    private func filteredEvents(for filter: String) -> [StoredEvent] {
        let trimmed = filter.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return model.selectedEvents }
        return model.selectedEvents.filter { event in
            if event.event.localizedStandardContains(trimmed) { return true }
            return payloadJSONString(for: event.payload).localizedStandardContains(trimmed)
        }
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

            #if DEBUG
            HStack {
                Button("Simulate Ingest") {
                    Task {
                        await model.simulateIngest()
                    }
                }
            }
            .buttonStyle(.bordered)
            #endif
        }
        .padding(.vertical, 10)
        .padding(.horizontal, 12)
        .background(.quinary)
        .clipShape(.rect(cornerRadius: 10))
        .padding([.top, .horizontal])
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
    let events: [StoredEvent]
    let filterText: String

    private var isFiltering: Bool {
        !filterText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        if model.selectedRunID == nil {
            if model.selectedRunIDs.count > 1 {
                ContentUnavailableView(
                    "Multiple Runs Selected",
                    systemImage: "rectangle.stack",
                    description: Text("\(model.selectedRunIDs.count) runs selected. Select a single run to view its events, or use the Delete button to remove them.")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ContentUnavailableView(
                    "Select a Run",
                    systemImage: "sidebar.left",
                    description: Text("Choose a run from the sidebar to view event details.")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        } else if events.isEmpty {
            if isFiltering {
                ContentUnavailableView(
                    "No Matches",
                    systemImage: "magnifyingglass",
                    description: Text("No events match the current filter.")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ContentUnavailableView(
                    "No Events Found",
                    systemImage: "list.bullet.rectangle",
                    description: Text("No events are available for the selected run/device filter.")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        } else {
            List(events) { event in
                VStack(alignment: .leading, spacing: 4) {
                    Text(event.event)
                        .bold()
                    Text("\(event.deviceID) • \(event.level.rawValue) • \(sequenceLabel(for: event))")
                        .font(.caption)
                    Text("event: \(localTimestampString(for: event.ts))")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .help("UTC: \(LogRollerJSONCoders.render(date: event.ts))")
                    Text("received: \(localTimestampString(for: event.recvTS))")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .help("UTC: \(LogRollerJSONCoders.render(date: event.recvTS))")
                    if let resourcesText = resourcesSummary(for: event.resources) {
                        Text("resources: \(resourcesText)")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    Text(payloadString(for: event.payload))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .lineLimit(3)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
                .onTapGesture(count: 2) {
                    copyEventJSON(event)
                }
                .contextMenu {
                    Button("Copy Event as JSON") {
                        copyEventJSON(event)
                    }
                    Button("Copy Payload") {
                        copyToPasteboard(payloadJSONString(for: event.payload))
                    }
                }
                .help("Double-click to copy event JSON")
            }
        }
    }

    private func copyEventJSON(_ event: StoredEvent) {
        guard let json = eventJSONString(for: event) else { return }
        copyToPasteboard(json)
    }

    private func sequenceLabel(for event: StoredEvent) -> String {
        guard let seq = event.seq else {
            return "seq unknown"
        }
        return "seq \(seq)"
    }

    private func payloadString(for payload: JSONValue) -> String {
        "payload: \(payloadJSONString(for: payload))"
    }

    private func resourcesSummary(for resources: JSONValue?) -> String? {
        guard case let .object(dict) = resources else { return nil }

        var parts: [String] = []
        if let memory = numberValue(dict["memory_bytes"]) {
            parts.append("mem \(byteString(memory))")
        }
        if let cpu = numberValue(dict["cpu_percent"]) {
            parts.append("cpu \(cpuString(cpu))")
        }
        if let threads = numberValue(dict["thread_count"]) {
            parts.append("threads \(Int(threads))")
        }
        if let disk = numberValue(dict["disk_free_bytes"]) {
            parts.append("disk \(byteString(disk)) free")
        }
        return parts.isEmpty ? nil : parts.joined(separator: " • ")
    }

    private func numberValue(_ value: JSONValue?) -> Double? {
        guard case let .number(number) = value else { return nil }
        return number
    }

    private func byteString(_ bytes: Double) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .memory)
    }

    private func cpuString(_ percent: Double) -> String {
        let rounded = (percent * 10).rounded() / 10
        if rounded == rounded.rounded() {
            return "\(Int(rounded))%"
        }
        return String(format: "%.1f%%", rounded)
    }
}
