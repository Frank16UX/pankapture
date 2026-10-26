import AutoEdit
import DesignSystem
import SwiftUI
import Transcription

extension AutoEditGroup {
    /// Tint for the group's items on the timeline and in the review list.
    var color: Color {
        switch self {
        case .pauses: .blue
        case .fillers: .orange
        case .repeats: .purple
        case .mistakes: .red
        }
    }
}

/// Inspector section: run auto-edit and choose what applies (PRD AE-1–AE-3, AE-7).
struct AutoEditSection: View {
    @Bindable var model: VideoEditorModel

    private var layer: AutoEditLayer? { model.project.autoEdit }

    var body: some View {
        Section {
            Picker("Language", selection: $model.autoEditLanguage) {
                ForEach(TranscriptLanguage.allCases) { Text($0.title).tag($0) }
            }
            .disabled(model.isAutoEditRunning)

            providerNote

            switch model.autoEditState {
            case let .running(stage, fraction):
                VStack(alignment: .leading, spacing: PK.Spacing.xs) {
                    HStack {
                        Text(stage).font(.callout)
                        Spacer()
                        Button("Cancel", action: model.cancelAutoEdit)
                            .controlSize(.small)
                    }
                    if let fraction {
                        ProgressView(value: fraction)
                    } else {
                        ProgressView().progressViewStyle(.linear)
                    }
                }
            case .idle, .failed:
                Button(layer == nil ? "Analyze Recording" : "Analyze Again", systemImage: "wand.and.sparkles") { model.runAutoEdit() }
                    .help("Transcribe the microphone and suggest what to remove. Keeps your transcript corrections.")
                if model.transcript != nil {
                    Button("Transcribe Again", systemImage: "arrow.clockwise") { model.runAutoEdit(retranscribe: true) }
                        .help("Transcribe from scratch (for example with a different transcription service). Discards transcript corrections.")
                }
            }

            if case let .failed(message) = model.autoEditState {
                Label(message, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.red)
            }
            if let notice = model.autoEditNotice {
                Text(notice)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if let layer {
                ForEach(AutoEditGroup.allCases) { group in
                    Toggle(isOn: Binding(
                        get: { layer.groups.contains(group) },
                        set: { model.setAutoEditGroup(group, isOn: $0) }
                    )) {
                        Label {
                            Text(group.title) + Text("  \(layer.count(of: group))").foregroundStyle(.secondary)
                        } icon: {
                            Image(systemName: group.systemImage).foregroundStyle(group.color)
                        }
                    }
                }

                FittingSegmentedPicker("Pacing", selection: Binding(get: { layer.pacing }, set: { model.setPacing($0) })) {
                    ForEach(Pacing.allCases) { Text($0.title).tag($0) }
                }
                .disabled(!layer.groups.contains(.pauses))
                .help("How much room pauses keep. Section breaks and pauses for emphasis always keep more.")

                Picker("Silent screen actions", selection: Binding(get: { layer.actionSpeed }, set: { model.setActionSpeed($0) })) {
                    Text("Keep").tag(Double?.none)
                    Text("2× faster").tag(Double?.some(2))
                    Text("4× faster").tag(Double?.some(4))
                }
                .disabled(!layer.groups.contains(.pauses))

                LabeledContent("Removes") {
                    let removed = layer.removedDuration
                    let share = model.duration > 0 ? removed / model.duration : 0
                    Text("\(Format.time(removed)) (\(Format.percent(share)))").monospacedDigit()
                }
                LabeledContent("Judged by", value: layer.judgedBy)

                Button("Remove Auto-Edit", systemImage: "xmark.circle", role: .destructive, action: model.clearAutoEdit)
                    .help("Remove every suggestion. Your own cuts stay.")
            }
        } header: {
            Text("Auto-Edit")
        } footer: {
            if layer != nil {
                Text("Suggestions sit on their own layer. Click one on the timeline or below to review it, drag its edges to adjust it, or press ⌫ to restore it. [ and ] move the selected cut's edges to the playhead.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder private var providerNote: some View {
        if let cloud = CloudTranscriptionSettings.active() {
            Label {
                VStack(alignment: .leading, spacing: PK.Spacing.xxs) {
                    Text("Transcribed by \(cloud.service.name)")
                    Text("Sends the microphone audio when you analyze. Change it in Settings ▸ AI.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } icon: {
                Image(systemName: "waveform.badge.mic").foregroundStyle(.orange)
            }
        }
        if let provider = model.autoEditProvider {
            Label {
                VStack(alignment: .leading, spacing: PK.Spacing.xxs) {
                    Text(provider.displayName)
                    Text(provider.isLocal
                         ? "Runs on this Mac. Only the transcript text is used."
                         : "Sends the transcript text and pause timings to \(provider.preset?.name ?? "the provider"), never audio or video.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } icon: {
                Image(systemName: "sparkles").foregroundStyle(Color.accentColor)
            }
        } else {
            Text("Built-in rules judge pauses and mistakes on this Mac. An AI provider in Settings ▸ AI judges them better.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

/// Burned-in captions from the transcript (PRD CAP-1, CAP-3, CAP-4).
struct CaptionsSection: View {
    @Bindable var model: VideoEditorModel

    private var settings: CaptionSettings { model.project.captions ?? CaptionSettings(isEnabled: false) }

    private func set(_ change: @escaping (inout CaptionSettings) -> Void) {
        model.edit { project in
            var captions = project.captions ?? CaptionSettings(isEnabled: false)
            change(&captions)
            project.captions = captions
        }
    }

    var body: some View {
        Section("Captions") {
            if model.transcript == nil {
                Text("Analyze the recording to get its transcript; captions are made from it.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Toggle("Show Captions", isOn: Binding(get: { settings.isEnabled }, set: { value in set { $0.isEnabled = value } }))
                Group {
                    FittingSegmentedPicker("Style", selection: Binding(get: { settings.style }, set: { value in set { $0.style = value } })) {
                        ForEach(CaptionSettings.Style.allCases) { Text($0.title).tag($0) }
                    }
                    FittingSegmentedPicker("Position", selection: Binding(get: { settings.position }, set: { value in set { $0.position = value } })) {
                        ForEach(CaptionSettings.Position.allCases) { Text($0.title).tag($0) }
                    }
                    FittingSegmentedPicker("Size", selection: Binding(get: { settings.size }, set: { value in set { $0.size = value } })) {
                        ForEach(CaptionSettings.Size.allCases) { Text($0.title).tag($0) }
                    }
                    Picker("Captions file", selection: Binding(get: { settings.fileFormat }, set: { value in set { $0.fileFormat = value } })) {
                        ForEach(CaptionSettings.FileFormat.allCases) { Text($0.title).tag($0) }
                    }
                    .help("Also save the captions as a file next to exported MP4s")
                    Text("Captions are burned into exports. Fix any word in the Transcript panel.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .disabled(!settings.isEnabled)
            }
        }
    }
}

/// Every suggestion, to check one by one (PRD AE-7). Removals switch on
/// and off; pauses take a kind or "keep as is" (AE-8).
struct AutoEditReviewSection: View {
    @Bindable var model: VideoEditorModel
    let layer: AutoEditLayer

    private enum Row: Identifiable {
        case removal(AutoEditLayer.Removal)
        case pause(AutoEditLayer.PauseItem)

        var id: AutoEditItem {
            switch self {
            case .removal(let removal): .removal(removal.id)
            case .pause(let pause): .pause(pause.id)
            }
        }

        var start: Double {
            switch self {
            case .removal(let removal): removal.range.start
            case .pause(let pause): pause.pause.range.start
            }
        }
    }

    /// Removals, and the pauses worth a decision: long ones, or ones the
    /// pacing would cut.
    private var rows: [Row] {
        let removals = layer.removals.map(Row.removal)
        let pauses = layer.pauses.filter { $0.pause.duration >= ModelPass.minimumJudgedPause || $0.isUserEdited }.map(Row.pause)
        return (removals + pauses).sorted { $0.start < $1.start }
    }

    var body: some View {
        Section("Review") {
            ForEach(rows) { row in
                switch row {
                case .removal(let removal): removalRow(removal)
                case .pause(let pause): pauseRow(pause)
                }
            }
        }
    }

    private func removalRow(_ removal: AutoEditLayer.Removal) -> some View {
        let isSelected = model.selectedAutoItem == .removal(removal.id)
        let applies = removal.isEnabled && layer.groups.contains(removal.group)
        return HStack(alignment: .top, spacing: PK.Spacing.s) {
            Image(systemName: removal.group.systemImage)
                .foregroundStyle(removal.group.color)
                .frame(width: 16)
            VStack(alignment: .leading, spacing: PK.Spacing.xxs) {
                HStack {
                    Text(removal.suggestion.kind.title).font(.callout.weight(.medium))
                    Spacer()
                    Text(Format.time(removal.range.start)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                }
                if !removal.text.isEmpty {
                    Text("“\(removal.text)”")
                        .font(.caption)
                        .strikethrough(applies)
                        .lineLimit(2)
                }
                Text(removal.suggestion.reason)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Toggle("Remove", isOn: Binding(get: { removal.isEnabled }, set: { model.setRemoval(removal.id, isEnabled: $0) }))
                .labelsHidden()
                .toggleStyle(.checkbox)
                .help(removal.isEnabled ? "Keep this part instead" : "Remove this part")
        }
        .padding(.vertical, 2)
        .listRowBackground(isSelected ? Color.accentColor.opacity(0.15) : nil)
        .opacity(layer.groups.contains(removal.group) ? 1 : 0.5)
        .contentShape(Rectangle())
        .onTapGesture { model.selectAutoItem(.removal(removal.id)) }
        .accessibilityElement(children: .combine)
        .accessibilityAction(named: removal.isEnabled ? "Keep" : "Remove") { model.setRemoval(removal.id, isEnabled: !removal.isEnabled) }
    }

    private func pauseRow(_ item: AutoEditLayer.PauseItem) -> some View {
        let isSelected = model.selectedAutoItem == .pause(item.id)
        let cut = item.cut(pacing: layer.pacing)
        return HStack(alignment: .top, spacing: PK.Spacing.s) {
            Image(systemName: AutoEditGroup.pauses.systemImage)
                .foregroundStyle(AutoEditGroup.pauses.color)
                .frame(width: 16)
            VStack(alignment: .leading, spacing: PK.Spacing.xxs) {
                HStack {
                    Text(String(format: "%.1f s pause", item.pause.duration))
                        .font(.callout.weight(.medium))
                        .fixedSize()
                    Spacer()
                    Text(Format.time(item.pause.range.start))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .fixedSize()
                }
                HStack {
                    Picker("Kind", selection: Binding(get: { item.pause.kind }, set: { model.setPauseKind(item.id, kind: $0) })) {
                        ForEach(PauseKind.allCases, id: \.self) { Text($0.title).tag($0) }
                    }
                    .labelsHidden()
                    .controlSize(.small)
                    .fixedSize()
                    .help(item.pause.kindSource == .user ? "Your choice" : "Judged by \(item.pause.kindSource == .model ? layer.judgedBy : "the built-in rules")")
                    Spacer()
                    Toggle("Keep as is", isOn: Binding(get: { item.keepsLength }, set: { model.setPause(item.id, keepsLength: $0) }))
                        .toggleStyle(.checkbox)
                        .controlSize(.small)
                        .help("Keep this pause as recorded")
                }
                Text(item.keepsLength ? "Kept as recorded" : cut.map { String(format: "Shortened by %.1f s", $0.duration) } ?? "Kept")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
        .listRowBackground(isSelected ? Color.accentColor.opacity(0.15) : nil)
        .opacity(layer.groups.contains(.pauses) ? 1 : 0.5)
        .contentShape(Rectangle())
        .onTapGesture { model.selectAutoItem(.pause(item.id)) }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(String(format: "%.1f second pause, %@", item.pause.duration, item.pause.kind.title))
    }
}
