import AppKit
import AutoEdit
import DesignSystem
import SwiftUI
import Transcription

/// The transcript pane (PRD AE-10, CAP-2): click a word to jump there;
/// select words to cut, restore, zoom, or correct them. Double-click a word
/// (or press Return on a selection) to fix it in place, or switch to Edit
/// Text to rewrite freely. Removed words are struck through, tinted by why.
struct TranscriptPanel: View {
    @Bindable var model: VideoEditorModel

    @State private var isEditingText = false
    @State private var draft = ""

    var body: some View {
        VStack(spacing: 0) {
            if let transcript = model.transcript {
                header(transcript)
                Divider()
                if isEditingText {
                    textEditor
                } else {
                    TranscriptTextView(
                        words: transcript.words,
                        states: model.wordStates(),
                        currentWord: model.wordIndex(atSource: model.playhead),
                        followsPlayhead: model.isPlaying,
                        selection: model.transcriptSelection,
                        correcting: model.wordsBeingCorrected,
                        actions: actions
                    )
                    Divider()
                    actionBar
                }
            } else {
                placeholder
            }
        }
        .onChange(of: model.transcript == nil) { _, isGone in if isGone { isEditingText = false } }
    }

    private var actions: TranscriptTextView.Actions {
        TranscriptTextView.Actions(
            clickWord: { model.seek(toWord: $0) },
            select: { model.transcriptSelection = $0 },
            beginCorrecting: { model.beginCorrecting($0) },
            endCorrecting: { model.wordsBeingCorrected = nil },
            cut: { model.cutWords($0) },
            zoom: { model.zoomWords($0) },
            isRemoved: { model.areWordsRemoved($0) },
            correction: { range in
                CorrectionPopover(
                    original: model.transcript?.text(of: range) ?? "",
                    otherOccurrences: model.otherOccurrences(of: range),
                    onCorrect: { text, everywhere in model.correctWords(range, to: text, everywhere: everywhere) },
                    onCancel: { model.wordsBeingCorrected = nil }
                )
            }
        )
    }

    private func header(_ transcript: Transcript) -> some View {
        HStack(spacing: PK.Spacing.s) {
            VStack(alignment: .leading, spacing: 0) {
                Text("\(transcript.words.count) words").font(.callout.weight(.medium))
                Text("\(transcript.language.title) · \(transcript.engine == Transcript.onDeviceEngine ? "On this Mac" : AIProvider.transcriptSource(transcript.engine) ?? transcript.engine)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if isEditingText {
                // No Return or Escape shortcuts: the text editor needs both.
                Button("Cancel", role: .cancel) { isEditingText = false }
                    .help("Discard the changes to the text")
                Button("Done") {
                    model.applyTranscriptText(draft)
                    isEditingText = false
                }
                .keyboardShortcut(.return, modifiers: .command)
                .buttonStyle(.borderedProminent)
                .help("Save the corrected text — ⌘↩")
            } else {
                Button("Edit Text", systemImage: "character.cursor.ibeam") {
                    draft = TranscriptEditing.text(of: transcript.words, paragraphPause: TranscriptTextView.paragraphPause)
                    model.transcriptSelection = nil
                    isEditingText = true
                }
                .help("Rewrite the transcript where it misheard you. The video isn't changed; captions use the new words.")
            }
        }
        .controlSize(.small)
        .padding(.horizontal, PK.Spacing.m)
        .padding(.vertical, PK.Spacing.s)
    }

    /// Free editing (CAP-2): words you don't touch keep their timing; changed
    /// words take the time of the words they replace.
    private var textEditor: some View {
        VStack(spacing: 0) {
            TextEditor(text: $draft)
                .font(.system(size: NSFont.systemFontSize + 1))
                .scrollContentBackground(.hidden)
                .padding(PK.Spacing.s)
                .accessibilityLabel("Transcript text")
            Divider()
            Label("Fix misheard words. Cutting happens in the video, not here: deleting text only removes it from the captions.",
                  systemImage: "info.circle")
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, PK.Spacing.m)
                .padding(.vertical, PK.Spacing.s)
        }
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
                .help(removed ? "Bring these words back — ⌫" : "Cut these words from the video — ⌫")
                Button("Zoom", systemImage: "plus.magnifyingglass") { model.zoomWords(range) }
                    .help("Zoom in while these words play")
                Button("Correct", systemImage: "pencil") { model.beginCorrecting(range) }
                    .help("Fix the words (captions use them) — ↩")
            }
            .controlSize(.small)
            .padding(.horizontal, PK.Spacing.m)
            .padding(.vertical, PK.Spacing.s)
        } else {
            Text("Click a word to jump there; double-click to correct it. Select words to cut, zoom, or correct them.")
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
                Button("Analyze Recording", systemImage: "wand.and.sparkles") {
                    model.inspectorSection = .autoEdit
                    model.runAutoEdit()
                }
                .disabled(model.isAutoEditRunning || model.media == nil)
            }
        }
        .padding(PK.Spacing.l)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Fixes the selected words in place, anchored to them (CAP-2). "Correct
/// All" also fixes every other place that reads the same, for a name the
/// recognizer keeps mishearing.
struct CorrectionPopover: View {
    let original: String
    let otherOccurrences: Int
    let onCorrect: (String, Bool) -> Void
    let onCancel: () -> Void

    @State private var text = ""
    @FocusState private var isFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: PK.Spacing.s) {
            Text("Correct").font(.headline)
            TextField("Words", text: $text)
                .textFieldStyle(.roundedBorder)
                .focused($isFocused)
                .frame(width: 280)
                .accessibilityLabel("Corrected words")
            Text("Captions use the corrected words. The video isn't changed.")
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack {
                Button("Cancel", role: .cancel, action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Spacer()
                if otherOccurrences > 0 {
                    Button("Correct All \(otherOccurrences + 1)") { onCorrect(text, true) }
                        .help("Also correct the \(otherOccurrences) other place\(otherOccurrences == 1 ? "" : "s") that read “\(original)”")
                }
                Button("Correct") { onCorrect(text, false) }
                    .keyboardShortcut(.defaultAction)
            }
            .controlSize(.small)
        }
        .padding(PK.Spacing.m)
        .onAppear {
            text = original
            isFocused = true
        }
    }
}

/// A read-only `NSTextView` (TextKit 1) of the words: native selection and
/// hit-testing, fast for thousands of words. The current word is a
/// temporary attribute, so playback doesn't rebuild the text. Corrections
/// open in a popover anchored to the words.
struct TranscriptTextView: NSViewRepresentable {
    struct Actions {
        var clickWord: (Int) -> Void
        var select: (ClosedRange<Int>?) -> Void
        var beginCorrecting: (ClosedRange<Int>) -> Void
        var endCorrecting: () -> Void
        var cut: (ClosedRange<Int>) -> Void
        var zoom: (ClosedRange<Int>) -> Void
        var isRemoved: (ClosedRange<Int>) -> Bool
        var correction: (ClosedRange<Int>) -> CorrectionPopover
    }

    var words: [TranscriptWord]
    var states: [VideoEditorModel.WordState]
    var currentWord: Int?
    var followsPlayhead: Bool
    var selection: ClosedRange<Int>?
    /// Words whose correction popover is open.
    var correcting: ClosedRange<Int>?
    var actions: Actions

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
        textView.onDoubleClick = { [weak coordinator] index in coordinator?.doubleClicked(characterIndex: index) }
        textView.menuProvider = { [weak coordinator] index in coordinator?.menu(atCharacter: index) }

        if coordinator.words != words || coordinator.states != states {
            coordinator.rebuild(words: words, states: states)
            coordinator.currentWord = nil
        }
        if coordinator.currentWord != currentWord {
            coordinator.highlight(currentWord, scroll: followsPlayhead)
        }
        coordinator.show(selection)
        coordinator.showCorrection(correcting)
    }

    static func dismantleNSView(_ scroll: NSScrollView, coordinator: Coordinator) {
        coordinator.showCorrection(nil)
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate, NSPopoverDelegate {
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
            parent?.actions.clickWord(index)
        }

        func doubleClicked(characterIndex: Int) {
            guard let index = word(atCharacter: characterIndex) else { return }
            parent?.actions.beginCorrecting(index...index)
        }

        // MARK: Context menu

        /// Correct, cut and zoom for the selected words, or for the word
        /// under the pointer when it's outside the selection.
        func menu(atCharacter characterIndex: Int) -> NSMenu? {
            guard let parent, let clicked = word(atCharacter: characterIndex) else { return nil }
            var range = clicked...clicked
            if let selection = parent.selection, selection.contains(clicked) {
                range = selection
            } else {
                parent.actions.select(range)
            }
            let actions = parent.actions
            let removed = actions.isRemoved(range)
            let menu = NSMenu()
            menu.addItem(ClosureMenuItem(title: "Correct…", symbol: "pencil") { actions.beginCorrecting(range) })
            menu.addItem(.separator())
            menu.addItem(ClosureMenuItem(title: removed ? "Restore" : "Cut", symbol: removed ? "arrow.uturn.backward" : "scissors") {
                actions.cut(range)
            })
            menu.addItem(ClosureMenuItem(title: "Zoom", symbol: "plus.magnifyingglass") { actions.zoom(range) })
            return menu
        }

        // MARK: Correction popover

        private var popover: NSPopover?
        private var popoverRange: ClosedRange<Int>?
        /// Set while the popover is closed on the model's behalf, so closing
        /// doesn't report back.
        private var isClosingPopover = false

        func showCorrection(_ range: ClosedRange<Int>?) {
            guard range != popoverRange else { return }
            if let popover {
                isClosingPopover = true
                popover.close()
                isClosingPopover = false
                self.popover = nil
            }
            popoverRange = range
            guard let range, let parent, let textView, let layout = textView.layoutManager, let container = textView.textContainer,
                  let first = ranges[safe: range.lowerBound], let last = ranges[safe: range.upperBound] else { return }
            let characters = NSRange(location: first.location, length: NSMaxRange(last) - first.location)
            let glyphs = layout.glyphRange(forCharacterRange: characters, actualCharacterRange: nil)
            // The first line of the words, so a long selection anchors at its start.
            var lineRange = NSRange()
            layout.lineFragmentRect(forGlyphAt: glyphs.location, effectiveRange: &lineRange)
            var rect = layout.boundingRect(forGlyphRange: NSIntersectionRange(glyphs, lineRange), in: container)
            rect.origin.x += textView.textContainerOrigin.x
            rect.origin.y += textView.textContainerOrigin.y
            textView.scrollToVisible(rect)

            let popover = NSPopover()
            popover.behavior = .transient
            popover.animates = !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
            let host = NSHostingController(rootView: parent.actions.correction(range))
            host.sizingOptions = .preferredContentSize
            popover.contentViewController = host
            popover.delegate = self
            popover.show(relativeTo: rect, of: textView, preferredEdge: .maxY)
            self.popover = popover
        }

        func popoverDidClose(_ notification: Notification) {
            guard (notification.object as? NSPopover) === popover else { return }
            popover = nil
            popoverRange = nil
            if !isClosingPopover { parent?.actions.endCorrecting() }
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            guard !isApplyingSelection, let textView else { return }
            let selected = textView.selectedRange()
            guard selected.length > 0, let first = word(atCharacter: selected.location),
                  let last = word(atCharacter: max(selected.location, NSMaxRange(selected) - 1)) else {
                parent?.actions.select(nil)
                return
            }
            parent?.actions.select(first...max(first, last))
        }
    }
}

/// Reports a click (no drag) or a double-click on a word, and asks for the
/// context menu; selection works as usual.
final class WordTextView: NSTextView {
    var onClick: ((Int) -> Void)?
    var onDoubleClick: ((Int) -> Void)?
    var menuProvider: ((Int) -> NSMenu?)?

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        super.mouseDown(with: event)
        // `super` tracks the drag; a plain click leaves an empty selection.
        if selectedRange().length == 0, event.clickCount == 1 {
            onClick?(characterIndexForInsertion(at: point))
        } else if event.clickCount == 2 {
            onDoubleClick?(characterIndex(at: point))
        }
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let point = convert(event.locationInWindow, from: nil)
        return menuProvider?(characterIndex(at: point)) ?? super.menu(for: event)
    }

    /// The character under `point` (not the insertion point between two).
    private func characterIndex(at point: NSPoint) -> Int {
        guard let layout = layoutManager, let container = textContainer else { return characterIndexForInsertion(at: point) }
        let local = NSPoint(x: point.x - textContainerOrigin.x, y: point.y - textContainerOrigin.y)
        return layout.characterIndex(for: local, in: container, fractionOfDistanceBetweenInsertionPoints: nil)
    }
}

/// A menu item that runs a closure.
private final class ClosureMenuItem: NSMenuItem {
    private let handler: () -> Void

    init(title: String, symbol: String, handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(run), keyEquivalent: "")
        target = self
        image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
    }

    @available(*, unavailable)
    required init(coder: NSCoder) { fatalError("init(coder:) is not used") }

    @objc private func run() { handler() }
}
