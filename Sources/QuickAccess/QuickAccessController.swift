import AppCore
import AppKit
import AVFoundation
import Capture
import DesignSystem
import SwiftUI

/// What a quick-access thumbnail shows.
public enum ThumbnailContent: @unchecked Sendable {
    // @unchecked: CGImage is an immutable CF type.
    case image(CGImage, scale: CGFloat)
    /// `size` is the video's pixel size (for the card's aspect ratio).
    case video(URL, size: CGSize)
}

public enum ThumbnailAction: Sendable {
    case copy, save, edit, pin, delete, reveal, open
}

/// One capture waiting in the corner stack.
@MainActor
@Observable
public final class QuickAccessItem: Identifiable {
    public let id = UUID()
    /// Replaceable: a recording's preview switches to the finished file.
    public var content: ThumbnailContent
    /// Where the capture was saved, if it was; used for dragging and reveal.
    public var fileURL: URL?
    /// History item, when recorded.
    public var libraryID: UUID?
    /// 0…1 while the file is still being produced (shown as a progress bar;
    /// only Edit and Close are offered), `nil` once it's ready.
    public var progress: Double?
    /// What the progress bar is doing, e.g. "Adding camera".
    public var progressTitle = ""

    public var isProcessing: Bool { progress != nil }

    init(content: ThumbnailContent, fileURL: URL?, libraryID: UUID?) {
        self.content = content
        self.fileURL = fileURL
        self.libraryID = libraryID
    }

    var isVideo: Bool {
        if case .video = content { return true }
        return false
    }

    /// A file to drag out: the saved file, or a temporary PNG.
    func draggableURL() -> URL? {
        guard !isProcessing else { return nil }
        if let fileURL { return fileURL }
        switch content {
        case let .video(url, _): return url
        case let .image(image, scale): return try? ImageOutput.writeTemporary(image, scale: scale)
        }
    }
}

/// The floating thumbnail stack in a screen corner (QA-1…QA-5).
@MainActor
public final class QuickAccessController {
    public static let shared = QuickAccessController()

    /// Handles the hover buttons. The item stays visible unless the app dismisses it.
    public var onAction: ((ThumbnailAction, QuickAccessItem) -> Void)?

    private var panels: [ThumbnailPanel] = []
    private static let maxVisible = 5
    private static let cardWidth: CGFloat = 220
    private static let gap: CGFloat = PK.Spacing.m
    private static let margin: CGFloat = PK.Spacing.l

    private init() {}

    @discardableResult
    public func show(_ content: ThumbnailContent, fileURL: URL? = nil, libraryID: UUID? = nil) -> QuickAccessItem {
        let item = QuickAccessItem(content: content, fileURL: fileURL, libraryID: libraryID)
        let size = Self.cardSize(for: content)
        let panel = ThumbnailPanel(item: item, size: size, controller: self)
        panels.append(panel)
        if panels.count > Self.maxVisible { dismiss(panels[0].item) }
        layout(animatedInsert: panel)
        return item
    }

    public func dismiss(_ item: QuickAccessItem) {
        guard let index = panels.firstIndex(where: { $0.item === item }) else { return }
        let panel = panels.remove(at: index)
        panel.slideOut(toRight: isRightSide)
        layout(animatedInsert: nil)
    }

    public func dismissAll() {
        for panel in panels { panel.slideOut(toRight: isRightSide) }
        panels.removeAll()
    }

    func perform(_ action: ThumbnailAction, on item: QuickAccessItem) {
        onAction?(action, item)
    }

    private var isRightSide: Bool {
        UserDefaults.standard.string(forKey: PreferenceKey.thumbnailPosition) != "left"
    }

    private static func cardSize(for content: ThumbnailContent) -> CGSize {
        let aspect: CGFloat
        switch content {
        case let .image(image, _):
            aspect = CGFloat(image.height) / CGFloat(max(image.width, 1))
        case let .video(_, size):
            aspect = size.width > 0 ? size.height / size.width : 9.0 / 16
        }
        return CGSize(width: cardWidth, height: min(max(cardWidth * aspect, 80), 220))
    }

    /// Newest at the bottom; older ones move up.
    private func layout(animatedInsert inserted: ThumbnailPanel?) {
        let screen = NSScreen.screens.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) } ?? NSScreen.main
        guard let visible = screen?.visibleFrame else { return }
        let right = isRightSide
        var y = visible.minY + Self.margin
        for panel in panels.reversed() {
            let size = panel.frame.size
            let x = right ? visible.maxX - Self.margin - size.width : visible.minX + Self.margin
            let target = CGRect(x: x, y: y, width: size.width, height: size.height)
            if panel === inserted {
                panel.slideIn(to: target, fromRight: right)
            } else {
                NSAnimationContext.runAnimationGroup { context in
                    context.duration = 0.25
                    context.allowsImplicitAnimation = true
                    panel.animator().setFrame(target, display: true)
                }
            }
            y += size.height + Self.gap
        }
    }
}

/// A floating, non-activating card.
final class ThumbnailPanel: NSPanel {
    let item: QuickAccessItem
    private unowned let controller: QuickAccessController
    private var dismissTask: Task<Void, Never>?
    private var swipe: CGFloat = 0

    init(item: QuickAccessItem, size: CGSize, controller: QuickAccessController) {
        self.item = item
        self.controller = controller
        super.init(contentRect: CGRect(origin: .zero, size: size), styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        isReleasedWhenClosed = false
        hidesOnDeactivate = false

        let card = ThumbnailCard(item: item, onAction: { [weak self] action in
            guard let self else { return }
            self.controller.perform(action, on: self.item)
        }, onClose: { [weak self] in
            guard let self else { return }
            self.controller.dismiss(self.item)
        }, onHover: { [weak self] hovering in
            hovering ? self?.cancelAutoDismiss() : self?.scheduleAutoDismiss()
        })
        let host = SwipeHostingView(rootView: card)
        host.onSwipe = { [weak self] deltaX in self?.handleSwipe(deltaX) }
        contentView = host
    }

    override var canBecomeKey: Bool { false }

    func slideIn(to target: CGRect, fromRight: Bool) {
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        var start = target
        start.origin.x += fromRight ? target.width + 40 : -(target.width + 40)
        setFrame(reduceMotion ? target : start, display: false)
        alphaValue = reduceMotion ? 0 : 1
        orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = reduceMotion ? 0.1 : 0.35
            context.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.9, 0.3, 1.05)
            animator().setFrame(target, display: true)
            animator().alphaValue = 1
        }
        scheduleAutoDismiss()
    }

    func slideOut(toRight: Bool) {
        cancelAutoDismiss()
        var end = frame
        end.origin.x += toRight ? frame.width + 40 : -(frame.width + 40)
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.25
            animator().setFrame(end, display: true)
            animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            MainActor.assumeIsolated { self?.orderOut(nil) }
        })
    }

    private func scheduleAutoDismiss() {
        cancelAutoDismiss()
        let seconds = UserDefaults.standard.double(forKey: PreferenceKey.thumbnailAutoDismissSeconds)
        guard seconds > 0 else { return }
        dismissTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            // Stay while the file is still being made, then give the user
            // the usual time with the finished one.
            var waited = false
            while !Task.isCancelled, self?.item.isProcessing == true {
                waited = true
                try? await Task.sleep(for: .milliseconds(500))
            }
            if waited { try? await Task.sleep(for: .seconds(seconds)) }
            guard !Task.isCancelled, let self else { return }
            self.controller.dismiss(self.item)
        }
    }

    private func cancelAutoDismiss() {
        dismissTask?.cancel()
        dismissTask = nil
    }

    /// Two-finger swipe toward the screen edge dismisses (QA-4).
    private func handleSwipe(_ deltaX: CGFloat) {
        swipe += deltaX
        let right = UserDefaults.standard.string(forKey: PreferenceKey.thumbnailPosition) != "left"
        if (right && swipe < -60) || (!right && swipe > 60) {
            swipe = 0
            controller.dismiss(item)
        }
    }
}

/// Forwards horizontal scroll gestures for swipe-to-dismiss.
private final class SwipeHostingView<Content: View>: NSHostingView<Content> {
    var onSwipe: ((CGFloat) -> Void)?

    override func scrollWheel(with event: NSEvent) {
        if abs(event.scrollingDeltaX) > abs(event.scrollingDeltaY) {
            onSwipe?(event.scrollingDeltaX)
        } else {
            super.scrollWheel(with: event)
        }
    }
}

// MARK: - Card

private struct ThumbnailCard: View {
    let item: QuickAccessItem
    let onAction: (ThumbnailAction) -> Void
    let onClose: () -> Void
    let onHover: (Bool) -> Void

    @State private var isHovering = false

    var body: some View {
        ZStack {
            preview
            if let progress = item.progress {
                ProcessingBar(title: item.progressTitle, progress: progress)
                    .frame(maxHeight: .infinity, alignment: .bottom)
                    .transition(.opacity)
            }
            if isHovering {
                hoverControls
                    .transition(.opacity)
            }
        }
        .animation(PK.Motion.quick, value: item.isProcessing)
        .clipShape(RoundedRectangle(cornerRadius: PK.Radius.thumbnail, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: PK.Radius.thumbnail, style: .continuous)
                .strokeBorder(.separator, lineWidth: PK.Metrics.hairline)
        )
        .onHover { hovering in
            withAnimation(PK.Motion.quick) { isHovering = hovering }
            onHover(hovering)
        }
        .onDrag {
            guard let url = item.draggableURL() else { return NSItemProvider() }
            return NSItemProvider(contentsOf: url) ?? NSItemProvider()
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(item.isVideo ? "Recording thumbnail" : "Screenshot thumbnail")
    }

    @ViewBuilder private var preview: some View {
        switch item.content {
        case let .image(image, _):
            Image(decorative: image, scale: 1)
                .resizable()
                .aspectRatio(contentMode: .fill)
        case let .video(url, _):
            VideoPreview(url: url, isPlaying: isHovering)
                .id(url)
        }
    }

    private var hoverControls: some View {
        ZStack {
            Rectangle().fill(.regularMaterial).opacity(0.85)

            VStack(spacing: PK.Spacing.s) {
                if item.isProcessing {
                    pill("Edit", "scissors", .edit)
                } else if item.isVideo {
                    pill("Edit", "scissors", .edit)
                    pill("Copy", "doc.on.doc", .copy)
                } else {
                    pill("Copy", "doc.on.doc", .copy)
                    pill(item.fileURL == nil ? "Save" : "Saved", item.fileURL == nil ? "square.and.arrow.down" : "checkmark", .save)
                        .disabled(item.fileURL != nil)
                }
            }

            VStack {
                HStack {
                    corner("Close", "xmark", action: onClose)
                    Spacer()
                    if !item.isVideo {
                        corner("Pin to Screen", "pin") { onAction(.pin) }
                    }
                }
                Spacer()
                if !item.isProcessing {
                    HStack {
                        if item.isVideo {
                            corner("Show in Finder", "folder") { onAction(.reveal) }
                        } else {
                            corner("Annotate", "pencil.tip.crop.circle") { onAction(.edit) }
                        }
                        Spacer()
                        corner("Delete", "trash") { onAction(.delete) }
                    }
                }
            }
            .padding(PK.Spacing.xs)
        }
    }

    private func pill(_ title: String, _ symbol: String, _ action: ThumbnailAction) -> some View {
        Button {
            onAction(action)
        } label: {
            Label(title, systemImage: symbol)
                .font(.callout.weight(.medium))
                .frame(minWidth: 96)
        }
        .buttonStyle(.bordered)
        .controlSize(.regular)
    }

    private func corner(_ title: String, _ symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: symbol).labelStyle(.iconOnly)
        }
        .buttonStyle(PKToolButtonStyle())
        .help(title)
    }
}

/// "Adding camera… 40%" along the bottom of a card whose file is still being made.
private struct ProcessingBar: View {
    let title: String
    let progress: Double

    var body: some View {
        VStack(alignment: .leading, spacing: PK.Spacing.xxs) {
            HStack {
                Text("\(title)…")
                Spacer(minLength: PK.Spacing.xs)
                Text(progress, format: .percent.precision(.fractionLength(0)))
                    .monospacedDigit()
            }
            .font(.caption.weight(.semibold))
            ProgressView(value: progress)
                .progressViewStyle(.linear)
                .controlSize(.small)
        }
        .padding(.horizontal, PK.Spacing.s)
        .padding(.vertical, PK.Spacing.xs)
        .background(.thickMaterial)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
        .accessibilityValue(Text(progress, format: .percent.precision(.fractionLength(0))))
    }
}

/// Muted looping preview that plays while hovered (QA-5).
private struct VideoPreview: NSViewRepresentable {
    let url: URL
    let isPlaying: Bool

    func makeNSView(context: Context) -> PlayerView {
        PlayerView(url: url)
    }

    func updateNSView(_ view: PlayerView, context: Context) {
        isPlaying ? view.player.play() : view.player.pause()
    }

    final class PlayerView: NSView {
        let player: AVQueuePlayer
        private let looper: AVPlayerLooper
        private let playerLayer: AVPlayerLayer

        init(url: URL) {
            let item = AVPlayerItem(url: url)
            player = AVQueuePlayer()
            player.isMuted = true
            looper = AVPlayerLooper(player: player, templateItem: item)
            playerLayer = AVPlayerLayer(player: player)
            playerLayer.videoGravity = .resizeAspectFill
            super.init(frame: .zero)
            wantsLayer = true
            layer?.addSublayer(playerLayer)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError() }

        override func layout() {
            super.layout()
            playerLayer.frame = bounds
        }
    }
}
