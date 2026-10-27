import AppCore
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

/// Auto-Edit's setup step: run the analysis and choose what applies (PRD
/// AE-1–AE-3, AE-7). Reviewing the suggestions is the next step.
struct AutoEditSection: View {
    @Bindable var model: VideoEditorModel

    private var layer: AutoEditLayer? { model.project.autoEdit }

    var body: some View {
        Section("Analyze") {
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
        }

        if let layer {
            Section {
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
            } header: {
                Text("Apply")
            } footer: {
                Text("Kinds switched off stay in the review, dimmed, so you can still look at them.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Result") {
                LabeledContent("Removes") {
                    let removed = layer.removedDuration
                    let share = model.duration > 0 ? removed / model.duration : 0
                    Text("\(Format.time(removed)) (\(Format.percent(share)))").monospacedDigit()
                }
                LabeledContent("Judged by", value: layer.judgedBy)
                Button("Review Suggestions", systemImage: "checklist") { model.autoEditPage = .review }
                    .help("Go through the suggestions one at a time")
                Button("Remove Auto-Edit", systemImage: "xmark.circle", role: .destructive, action: model.clearAutoEdit)
                    .help("Remove every suggestion. Your own cuts stay.")
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
        if model.transcript == nil {
            Section {
                Text("Analyze the recording to get its transcript; captions are made from it.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button("Analyze Recording", systemImage: "wand.and.sparkles") {
                    model.inspectorSection = .autoEdit
                    model.runAutoEdit()
                }
                .disabled(model.isAutoEditRunning)
            }
        } else {
            Section {
                Toggle("Show Captions", isOn: Binding(get: { settings.isEnabled }, set: { value in set { $0.isEnabled = value } }))
            }
            Section("Style") {
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
                }
                .disabled(!settings.isEnabled)
            }
            Section {
                Text("Captions are burned into exports. Fix a misheard word in the transcript.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button("Edit Transcript", systemImage: "text.quote") { model.inspectorSection = .transcript }
            }
        }
    }
}

/// Auto-Edit's review step (PRD AE-7, AE-8): every suggestion as a card, in
/// time order. The selected card opens up with the words around it, why it
/// was suggested, and its choices; the rest stay one or two lines, so the
/// list scans quickly. Picking a suggestion here or on the timeline selects
/// it in both, and the arrows step through them one at a time.
struct AutoEditReviewPane: View {
    @Bindable var model: VideoEditorModel
    let layer: AutoEditLayer

    @State private var filter: AutoEditGroup?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    enum Row: Identifiable {
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

        var group: AutoEditGroup {
            switch self {
            case .removal(let removal): removal.group
            case .pause: .pauses
            }
        }
    }

    /// Removals, and the pauses worth a decision: long ones, or ones the
    /// user already changed.
    static func rows(_ layer: AutoEditLayer) -> [Row] {
        let removals = layer.removals.map(Row.removal)
        let pauses = layer.pauses.filter { $0.pause.duration >= ModelPass.minimumJudgedPause || $0.isUserEdited }.map(Row.pause)
        return (removals + pauses).sorted { $0.start < $1.start }
    }

    static func itemCount(_ layer: AutoEditLayer) -> Int { rows(layer).count }

    var body: some View {
        let all = Self.rows(layer)
        let rows = filter.map { group in all.filter { $0.group == group } } ?? all
        VStack(spacing: 0) {
            summary(rows)
            filterBar(all)
            Divider()
            if rows.isEmpty {
                emptyState
            } else {
                list(rows)
            }
        }
    }

    // MARK: Header

    private func summary(_ rows: [Row]) -> some View {
        let ids = rows.map(\.id)
        let position = model.selectedAutoItem.flatMap(ids.firstIndex(of:))
        let removed = layer.removedDuration
        let share = model.duration > 0 ? removed / model.duration : 0
        return HStack(spacing: PK.Spacing.s) {
            VStack(alignment: .leading, spacing: 0) {
                Text("Removes \(Format.time(removed))")
                    .font(.callout.weight(.medium).monospacedDigit())
                Text("\(Format.percent(share)) of the recording")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: PK.Spacing.s)
            Text(position.map { "\($0 + 1) of \(ids.count)" } ?? "\(ids.count) to review")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
            ControlGroup {
                Button("Previous", systemImage: "chevron.up") { model.selectAutoItem(after: -1, in: ids) }
                    .disabled(ids.isEmpty || position == 0)
                    .help("Previous suggestion")
                Button("Next", systemImage: "chevron.down") { model.selectAutoItem(after: 1, in: ids) }
                    .disabled(ids.isEmpty || position == ids.count - 1)
                    .help("Next suggestion")
            }
            .labelStyle(.iconOnly)
            .controlSize(.small)
            .fixedSize()
        }
        .padding(.horizontal, PK.Spacing.l)
        .padding(.vertical, PK.Spacing.s)
    }

    /// Filter by kind: all, or one group, with how many each holds.
    private func filterBar(_ all: [Row]) -> some View {
        HStack(spacing: PK.Spacing.xs) {
            chip(nil, count: all.count)
            ForEach(AutoEditGroup.allCases) { group in
                let count = all.filter { $0.group == group }.count
                if count > 0 { chip(group, count: count) }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, PK.Spacing.l)
        .padding(.bottom, PK.Spacing.s)
    }

    private func chip(_ group: AutoEditGroup?, count: Int) -> some View {
        let isOn = filter == group
        return Button {
            filter = group
        } label: {
            HStack(spacing: PK.Spacing.xxs) {
                if let group {
                    Image(systemName: group.systemImage)
                        .foregroundStyle(group.color)
                } else {
                    Text("All")
                }
                Text("\(count)").monospacedDigit()
            }
            .font(.caption.weight(isOn ? .semibold : .regular))
            .padding(.horizontal, PK.Spacing.s)
            .padding(.vertical, PK.Spacing.xxs + 1)
            .background(Capsule().fill(isOn ? AnyShapeStyle(Color.accentColor.opacity(0.18)) : AnyShapeStyle(.quinary)))
            .overlay(Capsule().strokeBorder(isOn ? Color.accentColor : .clear, lineWidth: 1))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help(group.map { "Show only \($0.title.lowercased())" } ?? "Show every suggestion")
        .accessibilityLabel("\(group?.title ?? "All"), \(count)")
        .accessibilityAddTraits(isOn ? [.isButton, .isSelected] : .isButton)
    }

    private var emptyState: some View {
        VStack(spacing: PK.Spacing.s) {
            Image(systemName: "checkmark.circle")
                .font(.title)
                .foregroundStyle(.secondary)
            Text(filter == nil ? "Nothing to review" : "None of this kind")
                .font(.headline)
            Text("Auto-Edit found no pauses or mistakes worth a decision here.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(PK.Spacing.xl)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: List

    private func list(_ rows: [Row]) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: PK.Spacing.xs) {
                    ForEach(rows) { row in
                        ReviewCard(model: model, layer: layer, row: row, isSelected: model.selectedAutoItem == row.id)
                            .id(row.id)
                    }
                }
                .padding(PK.Spacing.m)
            }
            // A pick on the timeline shows here: the filter makes room for
            // it and the list scrolls it into view.
            .onChange(of: model.selectedAutoItem, initial: true) { _, item in
                guard let item else { return }
                if let filter, rows.first(where: { $0.id == item })?.group != filter {
                    self.filter = nil
                }
                withAnimation(reduceMotion ? nil : PK.Motion.standard) {
                    proxy.scrollTo(item, anchor: .center)
                }
            }
        }
    }
}

/// One suggestion in the review.
private struct ReviewCard: View {
    @Bindable var model: VideoEditorModel
    let layer: AutoEditLayer
    let row: AutoEditReviewPane.Row
    let isSelected: Bool

    private var groupApplies: Bool { layer.groups.contains(row.group) }

    var body: some View {
        VStack(alignment: .leading, spacing: PK.Spacing.xs) {
            HStack(alignment: .firstTextBaseline, spacing: PK.Spacing.s) {
                Image(systemName: row.group.systemImage)
                    .foregroundStyle(row.group.color)
                    .frame(width: 16)
                Text(title)
                    .font(.callout.weight(.medium))
                    .lineLimit(1)
                Spacer(minLength: PK.Spacing.xs)
                Text(Format.time(row.start))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                if case .removal(let removal) = row {
                    Toggle("Remove", isOn: Binding(get: { removal.isEnabled }, set: { model.setRemoval(removal.id, isEnabled: $0) }))
                        .labelsHidden()
                        .toggleStyle(.checkbox)
                        .help(removal.isEnabled ? "Keep this part instead" : "Remove this part")
                }
            }
            context
                .font(.callout)
                .lineLimit(isSelected ? nil : 2)
                .padding(.leading, 16 + PK.Spacing.s)
            if isSelected { details.padding(.leading, 16 + PK.Spacing.s) }
        }
        .padding(PK.Spacing.s)
        .background {
            RoundedRectangle(cornerRadius: PK.Radius.thumbnail, style: .continuous)
                .fill(isSelected ? AnyShapeStyle(Color.accentColor.opacity(0.12)) : AnyShapeStyle(.quinary))
        }
        .overlay {
            RoundedRectangle(cornerRadius: PK.Radius.thumbnail, style: .continuous)
                .strokeBorder(isSelected ? Color.accentColor : .clear, lineWidth: 1.5)
        }
        .opacity(groupApplies ? 1 : 0.55)
        .contentShape(Rectangle())
        .onTapGesture { if !isSelected { model.selectAutoItem(row.id) } }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(title) at \(Format.time(row.start))")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityAction(named: "Select") { model.selectAutoItem(row.id) }
    }

    private var title: String {
        switch row {
        case .removal(let removal): removal.suggestion.kind.title
        case .pause(let item): String(format: "%.1f s pause", item.pause.duration)
        }
    }

    /// The words around the suggestion; what it removes is struck through.
    private var context: Text {
        let range: TimeRange
        let inside: Text
        switch row {
        case .removal(let removal):
            range = removal.range
            let applies = removal.isEnabled && groupApplies
            let words = removal.text.isEmpty ? "(no words)" : removal.text
            inside = Text(words).strikethrough(applies, color: row.group.color).foregroundStyle(applies ? .secondary : .primary)
        case .pause(let item):
            range = item.pause.range
            let cut = item.keepsLength ? nil : item.cut(pacing: layer.pacing)
            let label = cut.map { String(format: "%.1f s → %.1f s", item.pause.duration, item.pause.duration - $0.duration) } ?? "kept"
            inside = Text(" ⏸ \(label) ").foregroundStyle(row.group.color)
        }
        let around = model.words(around: range, count: isSelected ? 8 : 4)
        let before = around.before.isEmpty ? Text("") : Text("…\(around.before) ").foregroundStyle(.secondary)
        let after = around.after.isEmpty ? Text("") : Text(" \(around.after)…").foregroundStyle(.secondary)
        return Text("\(before)\(inside)\(after)")
    }

    @ViewBuilder private var details: some View {
        switch row {
        case .removal(let removal):
            Text(removal.suggestion.reason)
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack(spacing: PK.Spacing.s) {
                playButton(removal.range)
                Spacer()
                Button(removal.isEnabled ? "Keep It" : "Remove It",
                       systemImage: removal.isEnabled ? "arrow.uturn.backward" : "scissors") {
                    model.setRemoval(removal.id, isEnabled: !removal.isEnabled)
                }
                .help(removal.isEnabled ? "Keep this part — ⌫" : "Remove this part")
            }
            .controlSize(.small)
        case .pause(let item):
            HStack {
                Picker("Kind", selection: Binding(get: { item.pause.kind }, set: { model.setPauseKind(item.id, kind: $0) })) {
                    ForEach(PauseKind.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                .fixedSize()
                .help(item.pause.kindSource == .user ? "Your choice" : "Judged by \(item.pause.kindSource == .model ? layer.judgedBy : "the built-in rules")")
                Spacer()
                Toggle("Keep as is", isOn: Binding(get: { item.keepsLength }, set: { model.setPause(item.id, keepsLength: $0) }))
                    .toggleStyle(.checkbox)
                    .help("Keep this pause as recorded — ⌫")
            }
            .controlSize(.small)
            HStack {
                playButton(item.pause.range)
                Spacer()
            }
            .controlSize(.small)
        }
        if !groupApplies {
            Text("\(row.group.title) are switched off in Setup, so this isn't applied.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func playButton(_ range: TimeRange) -> some View {
        Button("Play", systemImage: "play.fill") {
            model.seek(toSource: max(0, range.start - 1.5))
            model.play()
        }
        .help("Play from just before it — Space")
    }
}
