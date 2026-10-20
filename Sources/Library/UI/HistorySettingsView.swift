import AppCore
import DesignSystem
import SwiftUI

/// Settings → History tab (HI-5, OUT-8). The app adds it to its Settings `TabView`:
///
/// ```swift
/// Tab("History", systemImage: "clock.arrow.circlepath") {
///     HistorySettingsView(library: library) { libraryWindow.show() }
/// }
/// ```
public struct HistorySettingsView: View {
    private let library: CaptureLibrary
    private let openLibrary: () -> Void

    @AppStorage(PreferenceKey.historyEnabled) private var isEnabled = true
    @AppStorage(PreferenceKey.historyKeepsUnsavedCaptures) private var keepsUnsaved = true
    @AppStorage(PreferenceKey.historyRetention) private var retention = HistoryRetention.forever.rawValue
    @AppStorage(PreferenceKey.historyStorageCapGB) private var storageCapGB = 0.0

    @State private var storageUsed: Int64?
    @State private var itemCount = 0
    @State private var isConfirmingClear = false
    @State private var pendingPolicy: PendingPolicy?

    private static let capChoices: [Double] = [1, 2, 5, 10, 25, 50]

    /// A retention/cap change that would delete captures, awaiting confirmation.
    private struct PendingPolicy: Identifiable {
        let id = UUID()
        var retention: HistoryRetention
        var storageCapGB: Double
        var affectedCount: Int
    }

    public init(library: CaptureLibrary, openLibrary: @escaping () -> Void) {
        self.library = library
        self.openLibrary = openLibrary
    }

    public var body: some View {
        Form {
            Section {
                Toggle("Keep a history of captures", isOn: $isEnabled)
                Toggle("Include captures closed without saving", isOn: $keepsUnsaved)
                    .disabled(!isEnabled)
            } footer: {
                Text("Find, re-edit, and share past screenshots and recordings. History stays on this Mac.")
                    .foregroundStyle(.secondary)
            }

            Section {
                Picker("Keep captures", selection: retentionBinding) {
                    ForEach(HistoryRetention.allCases) { Text($0.title).tag($0) }
                }
                Picker("Storage limit", selection: capBinding) {
                    Text("No Limit").tag(0.0)
                    ForEach(Self.capChoices, id: \.self) { Text("\(Int($0)) GB").tag($0) }
                }
                LabeledContent("Space used") {
                    Text(storageUsed.map(LibraryFormat.bytes) ?? "—").monospacedDigit()
                }
                LabeledContent("Captures") {
                    Text("\(itemCount)").monospacedDigit()
                }
            } header: {
                Text("Storage")
            } footer: {
                Text("When a limit is reached, the oldest captures are removed first. Files you saved are never deleted.")
                    .foregroundStyle(.secondary)
            }

            Section {
                HStack {
                    Button("Open Library…", action: openLibrary)
                    Spacer()
                    Button("Clear History…", role: .destructive) { isConfirmingClear = true }
                        .disabled(itemCount == 0)
                }
            }
        }
        .formStyle(.grouped)
        .task(id: library.revision) { await refreshStats() }
        .confirmationDialog("Clear the entire history?", isPresented: $isConfirmingClear, titleVisibility: .visible) {
            Button("Clear History", role: .destructive) {
                Task { await library.deleteAll() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This removes \(itemCount) capture\(itemCount == 1 ? "" : "s") from the library. Files you saved aren't affected.")
        }
        .confirmationDialog(
            pendingTitle,
            isPresented: Binding(get: { pendingPolicy != nil }, set: { if !$0 { pendingPolicy = nil } }),
            titleVisibility: .visible,
            presenting: pendingPolicy
        ) { policy in
            Button("Remove Captures", role: .destructive) { apply(policy) }
            Button("Cancel", role: .cancel) { pendingPolicy = nil }
        } message: { _ in
            Text("Files you saved aren't affected.")
        }
    }

    private var pendingTitle: String {
        let count = pendingPolicy?.affectedCount ?? 0
        return "This setting removes \(count) capture\(count == 1 ? "" : "s") now."
    }

    private var currentRetention: HistoryRetention {
        HistoryRetention(rawValue: retention) ?? .forever
    }

    private var retentionBinding: Binding<HistoryRetention> {
        Binding(
            get: { currentRetention },
            set: { propose(retention: $0, storageCapGB: storageCapGB) }
        )
    }

    private var capBinding: Binding<Double> {
        Binding(
            get: { storageCapGB },
            set: { propose(retention: currentRetention, storageCapGB: $0) }
        )
    }

    /// Applies a policy right away if it deletes nothing; otherwise asks first.
    private func propose(retention: HistoryRetention, storageCapGB: Double) {
        Task {
            let count = await library.retentionPreview(retention: retention, storageCapGB: storageCapGB)
            let policy = PendingPolicy(retention: retention, storageCapGB: storageCapGB, affectedCount: count)
            if count == 0 {
                apply(policy)
            } else {
                pendingPolicy = policy
            }
        }
    }

    private func apply(_ policy: PendingPolicy) {
        retention = policy.retention.rawValue
        storageCapGB = policy.storageCapGB
        pendingPolicy = nil
        Task { await library.applyRetention() }
    }

    private func refreshStats() async {
        itemCount = await library.count()
        storageUsed = await library.storageUsed()
    }
}
