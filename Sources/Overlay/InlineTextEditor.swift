import Annotation
import AppKit
import Carbon.HIToolbox

/// The in-place text field used by the text tool. Font, padding, and origin
/// match `AnnotationRenderer`'s text drawing, so committing doesn't shift text.
final class InlineTextEditor: NSTextView {
    let textOrigin: CGPoint
    let fontSize: Double
    let color: RGBAColor
    var existingID: Annotation.ID?
    var onCommit: (() -> Void)?

    init(origin: CGPoint, string: String, fontSize: Double, color: RGBAColor) {
        self.textOrigin = origin
        self.fontSize = fontSize
        self.color = color
        let container = NSTextContainer(size: CGSize(width: CGFloat.greatestFiniteMagnitude, height: .greatestFiniteMagnitude))
        container.lineFragmentPadding = 0
        container.widthTracksTextView = false
        let layoutManager = NSLayoutManager()
        layoutManager.addTextContainer(container)
        let storage = NSTextStorage()
        storage.addLayoutManager(layoutManager)
        super.init(frame: CGRect(origin: origin, size: TextMetrics.size(of: string, fontSize: fontSize)),
                   textContainer: container)

        drawsBackground = false
        isRichText = false
        allowsUndo = true
        isHorizontallyResizable = true
        isVerticallyResizable = true
        textContainerInset = .zero
        isAutomaticQuoteSubstitutionEnabled = false
        isAutomaticDashSubstitutionEnabled = false
        isAutomaticSpellingCorrectionEnabled = false
        font = TextMetrics.font(size: fontSize)
        textColor = NSColor(cgColor: color.cgColor)
        insertionPointColor = NSColor(cgColor: color.cgColor) ?? .white
        typingAttributes = TextMetrics.attributes(fontSize: fontSize, color: color)
        self.string = string
        resizeToFit()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override init(frame frameRect: NSRect, textContainer container: NSTextContainer?) {
        fatalError("Use init(origin:string:fontSize:color:)")
    }

    override func didChangeText() {
        super.didChangeText()
        resizeToFit()
    }

    private func resizeToFit() {
        let size = TextMetrics.size(of: string, fontSize: fontSize)
        // Room for the caret at the end of the line.
        setFrameSize(CGSize(width: size.width + 4, height: size.height))
    }

    override func keyDown(with event: NSEvent) {
        let keyCode = Int(event.keyCode)
        if keyCode == kVK_Escape
            || (event.modifierFlags.contains(.command) && (keyCode == kVK_Return || keyCode == kVK_ANSI_KeypadEnter)) {
            onCommit?()
            return
        }
        super.keyDown(with: event)
    }

    override func resignFirstResponder() -> Bool {
        let resigned = super.resignFirstResponder()
        if resigned { DispatchQueue.main.async { [weak self] in self?.onCommit?() } }
        return resigned
    }
}
