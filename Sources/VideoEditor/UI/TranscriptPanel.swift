import AppKit
import AutoEdit
import DesignSystem
import SwiftUI
import Transcription

/// The transcript next to the preview (PRD AE-10): click a word to jump
/// there; select words to cut, restore, zoom, or correct them (CAP-2).
/// Removed words are struck through, tinted by why.
struct TranscriptPanel: View {
    @Bindable var model: VideoEditorModel

    @State private var correction = ""
    @State private var correcting: ClosedRange<Int>?

    var body: some View {
        VStack(spacing: 0) {
            if let transcript = model.transcript {
                header(transcript)
                Divider()
                TranscriptTextView(
                    words: transcript.words,
                    states: model.wordStates(),
                    currentWord: model.wordIndex(atSource: model.playhead),
                    followsPlayhead: model.isPlaying,
                    selection: model.transcriptSelection,
                    onClickWord: { model.seek(toWord: $0) },
                    onSelect: { model.transcriptSelection = $0 }
                )
                Divider()
                actionBar
            } else {
                placeholder
            }
        }
        .sheet(item: Binding(get: { correcting.map(Correction.init) }, set: { correcting = $0?.range })) { item in
            correctionSheet(item.range)
        }
    }

    private struct Correction: Identifiable {
        var range: ClosedRange<Int>
        var id: Int { range.lowerBound * 100_000 + range.upperBound }
    }

    private func header(_ transcript: Transcript) -> some View {
        HStack {
            Text("\(transcript.words.count) words").font(.callout.weight(.medium))
            Spacer()
            Text("\(transcript.language.title) · \(transcript.engine == Transcript.onDeviceEngine ? "On this Mac" : transcript.engine)")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, PK.Spacing.m)
        .padding(.vertical, PK.Spacing.s)
    }

    @ViewBuilder private var actionBar: some View {
        if let range = model.transcriptSelection {
            let removed = model.areWordsRemoved(range)
            HStack(spacing: PK.Spacing.s) {
                Text("\(range.count) word\(range.count == 1 ? "" : "s")")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button(removed ? "Restore" : "Cut", systemImage: removed ? "arrow.uturn.backward" : "scissors") {
                    model.cutWords(range)
                }
                .help(removed ? "Bring these words back — ⌫" : "Cut these words — ⌫")
                Button("Zoom", systemImage: "plus.magnifyingglass") { model.zoomWords(range) }
                    .help("Zoom in while these words play")
                Button("Correct…", systemImage: "pencil") {
                    correction = model.transcript?.text(of: range) ?? ""
                    correcting = range
                }
                .help("Fix the transcript text (captions use it)")
            }
            .labelStyle(.iconOnly)
            .controlSize(.small)
            .padding(.horizontal, PK.Spacing.m)
            .padding(.vertical, PK.Spacing.s)
        } else {
            Text("Click a word to jump there. Select words to cut, zoom, or correct them.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, PK.Spacing.m)
                .padding(.vertical, PK.Spacing.s)
        }
    }

    private var placeholder: some View {
        VStack(spacing: PK.Spacing.m) {
            Image(systemName: "text.quote")
                .font(.largeTitle)
                .foregroundStyle(.secondary)
            Text("No Transcript").font(.headline)
            Text("Analyze the recording to transcribe its microphone on this Mac.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            if model.isAutoEditAvailable {
                Button("Analyze Recording", systemImage: "wand.and.sparkles") { model.runAutoEdit() }
                    .disabled(model.isAutoEditRunning || model.media == nil)
            }
        }
        .padding(PK.Spacing.l)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func correctionSheet(_ range: ClosedRange<Int>) -> some View {
        VStack(alignment: .leading, spacing: PK.Spacing.m) {
            Text("Correct the Transcript").font(.headline)
            Text("Captions use the corrected words. The video isn't changed.")
                .font(.callout)
                .foregroundStyle(.secondary)
            TextField("Words", text: $correction, axis: .vertical)
                .lineLimit(2...6)
                .textFieldStyle(.roundedBorder)
                .frame(width: 360)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { correcting = nil }
                    .keyboardShortcut(.cancelAction)
                Button("Save") {
                    model.correctWords(range, to: correction)
                    correcting = nil
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(PK.Spacing.l)
    }
}

/// A read-only `NSTextView` (TextKit 1) of the words: native selection and
/// hit-testing, fast for thousands of words. The current word is a
/// temporary attribute, so playback doesn't rebuild the text.
struct TranscriptTextView: NSViewRepresentable {
    var words: [TranscriptWord]
    var states: [VideoEditorModel.WordState]
    var currentWord: Int?
    var followsPlayhead: Bool
    var selection: ClosedRange<Int>?
    var onClickWord: (Int) -> Void
    var onSelect: (ClosedRange<Int>?) -> Void

    /// A pause this long starts a new paragraph.
    static let paragraphPause = 1.5

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSScrollView {
        let storage = NSTextStorage()
        let layout = NSLayoutManager()
        storage.addLayoutManager(layout)
        let container = NSTextContainer(size: CGSize(width: 0, height: CGFloat.greatestFiniteMagnitude))
        container.widthTracksTextView = true
        layout.addTextContainer(container)

        let textView = WordTextView(frame: .zero, textContainer: container)
        textView.isEditable = false
        textView.isSelectable = true
        textView.drawsBackground = false
        textView.textContainerInset = NSSize(width: 10, height: 10)
        textView.isVerticallyResizable = true
        textView.autoresizingMask = [.width]
        textView.delegate = context.coordinator
        textView.setAccessibilityLabel("Transcript")

        let scroll = NSScrollView()
        scroll.documentView = textView
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        context.coordinator.textView = textView
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        let coordinator = context.coordinator
        coordinator.parent = self
        guard let textView = coordinator.textView else { return }
        textView.onClick = { [weak coordinator] index in coordinator?.clicked(characterIndex: index) }

        if coordinator.words != words || coordinator.states != states {
            coordinator.rebuild(words: words, states: states)
            coordinator.currentWord = nil
        }
        if coordinator.currentWord != currentWord {
            coordinator.highlight(currentWord, scroll: followsPlayhead)
        }
        coordinator.show(selection)
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: TranscriptTextView?
        weak var textView: WordTextView?
        var words: [TranscriptWord] = []
        var states: [VideoEditorModel.WordState] = []
        var currentWord: Int?
        var isApplyingSelection = false
        /// Character range of each word in the text.
        private var ranges: [NSRange] = []

        func rebuild(words: [TranscriptWord], states: [VideoEditorModel.WordState]) {
            self.words = words
            self.states = states
            guard let textView, let storage = textView.textStorage else { return }
            // Replacing the text resets the selection; that isn't the user's doing.
            isApplyingSelection = true
            defer { isApplyingSelection = false }
            let paragraph = NSMutableParagraphStyle()
            paragraph.lineSpacing = 4
            paragraph.paragraphSpacing = 8
            let base: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: NSFont.systemFontSize + 1),
                .foregroundColor: NSColor.labelColor,
                .paragraphStyle: paragraph,
            ]
            let text = NSMutableAttributedString()
            ranges = []
            ranges.reserveCapacity(words.count)
            for (index, word) in words.enumerated() {
                var attributes = base
                switch states[safe: index] ?? .kept {
                case .kept: break
                case .trimmed:
                    attributes[.foregroundColor] = NSColor.tertiaryLabelColor
                case .cut:
                    attributes[.foregroundColor] = NSColor.secondaryLabelColor
                    attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue
                    attributes[.strikethroughColor] = NSColor.secondaryLabelColor
                case .autoRemoved(let group):
                    attributes[.foregroundColor] = NSColor.secondaryLabelColor
                    attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue
                    attributes[.strikethroughColor] = NSColor(group.color)
                }
                ranges.append(NSRange(location: text.length, length: (word.text as NSString).length))
                text.append(NSAttributedString(string: word.text, attributes: attributes))
                let next = words[safe: index + 1]
                let separator = next.map { $0.start - word.end >= TranscriptTextView.paragraphPause } == true ? "\n" : " "
                text.append(NSAttributedString(string: separator, attributes: base))
            }
            let visible = textView.visibleRect
            storage.setAttributedString(text)
            textView.scroll(visible.origin)
        }

        func highlight(_ index: Int?, scroll: Bool) {
            guard let textView, let layout = textView.layoutManager else { return }
            if let previous = currentWord, let range = ranges[safe: previous] {
                layout.removeTemporaryAttribute(.backgroundColor, forCharacterRange: range)
            }
            currentWord = index
            guard let index, let range = ranges[safe: index] else { return }
            layout.addTemporaryAttribute(.backgroundColor, value: NSColor.controlAccentColor.withAlphaComponent(0.25), forCharacterRange: range)
            if scroll { textView.scrollRangeToVisible(range) }
        }

        /// Makes the text view's selection match the model's (e.g. cleared
        /// after a cut, or set by undo).
        func show(_ selection: ClosedRange<Int>?) {
            guard let textView else { return }
            var target = NSRange(location: textView.selectedRange().location, length: 0)
            if let selection, let first = ranges[safe: selection.lowerBound], let last = ranges[safe: selection.upperBound] {
                target = NSRange(location: first.location, length: NSMaxRange(last) - first.location)
            }
            guard target != textView.selectedRange(), selection != nil || textView.selectedRange().length > 0 else { return }
            isApplyingSelection = true
            textView.setSelectedRange(target)
            isApplyingSelection = false
        }

        /// The word at a character index (or the one right before it).
        private func word(atCharacter index: Int) -> Int? {
            guard !ranges.isEmpty else { return nil }
            var low = 0
            var high = ranges.count - 1
            while low < high {
                let middle = (low + high + 1) / 2
                if ranges[middle].location <= index { low = middle } else { high = middle - 1 }
            }
            return low
        }

        func clicked(characterIndex: Int) {
            guard let index = word(atCharacter: characterIndex) else { return }
            parent?.onClickWord(index)
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            guard !isApplyingSelection, let textView else { return }
            let selected = textView.selectedRange()
            guard selected.length > 0, let first = word(atCharacter: selected.location),
                  let last = word(atCharacter: max(selected.location, NSMaxRange(selected) - 1)) else {
                parent?.onSelect(nil)
                return
            }
            parent?.onSelect(first...max(first, last))
        }
    }
}

/// Reports a click (no drag) on a word; selection works as usual.
final class WordTextView: NSTextView {
    var onClick: ((Int) -> Void)?

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        super.mouseDown(with: event)
        // `super` tracks the drag; a plain click leaves an empty selection.
        if selectedRange().length == 0, event.clickCount == 1 {
            onClick?(characterIndexForInsertion(at: point))
        }
    }
}
