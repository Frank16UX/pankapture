import Annotation
import AppKit
import DesignSystem
import SwiftUI

/// Vertical tools bar attached to the selection (DESIGN §7, AN-1…AN-3).
struct ToolsBar: View {
    @Bindable var state: EditorState
    @State private var showsStyle = false

    var body: some View {
        VStack(spacing: PK.Spacing.xxs) {
            ForEach(AnnotationTool.allCases) { tool in
                Button {
                    state.toggle(tool)
                } label: {
                    Label(tool.title, systemImage: tool.symbolName).labelStyle(.iconOnly)
                }
                .buttonStyle(PKToolButtonStyle(isSelected: state.tool == tool))
                .help("\(tool.title) — \(String(tool.keyEquivalent).uppercased())")
            }

            Divider().frame(width: PK.Metrics.toolButton - PK.Spacing.s).padding(.vertical, PK.Spacing.xxs)

            Button {
                showsStyle.toggle()
            } label: {
                Circle()
                    .fill(Color(cgColor: state.color.cgColor))
                    .overlay(Circle().strokeBorder(.primary.opacity(0.25), lineWidth: 1))
                    .frame(width: swatchSize, height: swatchSize)
                    .accessibilityLabel("Color and size")
            }
            .buttonStyle(PKToolButtonStyle())
            .help("Color and size")
            .popover(isPresented: $showsStyle, arrowEdge: .leading) {
                StylePicker(state: state)
            }

            Divider().frame(width: PK.Metrics.toolButton - PK.Spacing.s).padding(.vertical, PK.Spacing.xxs)

            Button { state.perform?(.undo) } label: {
                Label("Undo", systemImage: "arrow.uturn.backward").labelStyle(.iconOnly)
            }
            .buttonStyle(PKToolButtonStyle())
            .disabled(!state.canUndo)
            .help("Undo — ⌘Z")

            Button { state.perform?(.redo) } label: {
                Label("Redo", systemImage: "arrow.uturn.forward").labelStyle(.iconOnly)
            }
            .buttonStyle(PKToolButtonStyle())
            .disabled(!state.canRedo)
            .help("Redo — ⇧⌘Z")
        }
        .padding(PK.Spacing.xs)
        .pkSurface()
        .fixedSize()
    }

    private var swatchSize: CGFloat {
        switch state.size {
        case .small: PK.Metrics.swatch - 4
        case .medium: PK.Metrics.swatch
        case .large: PK.Metrics.swatch + 2
        }
    }
}

/// Color swatches, custom color, and size (AN-3).
private struct StylePicker: View {
    @Bindable var state: EditorState

    private let columns = Array(repeating: GridItem(.fixed(PK.Metrics.toolButton), spacing: PK.Spacing.xs), count: 4)

    var body: some View {
        VStack(alignment: .leading, spacing: PK.Spacing.m) {
            LazyVGrid(columns: columns, spacing: PK.Spacing.xs) {
                ForEach(RGBAColor.palette, id: \.self) { color in
                    Button {
                        state.setColor(color)
                    } label: {
                        Circle()
                            .fill(Color(cgColor: color.cgColor))
                            .overlay(Circle().strokeBorder(.primary.opacity(0.2), lineWidth: 1))
                            .padding(3)
                            .overlay(
                                Circle().strokeBorder(Color.accentColor, lineWidth: 2)
                                    .opacity(state.color == color ? 1 : 0)
                            )
                            .frame(width: PK.Metrics.toolButton, height: PK.Metrics.toolButton)
                            .contentShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(Self.name(of: color))
                }
            }

            ColorPicker("Custom color", selection: customColor, supportsOpacity: false)
                .onAppear {
                    // Over the capture overlay, the color panel must float above it.
                    if OverlayController.current != nil {
                        NSColorPanel.shared.level = NSWindow.Level(rawValue: OverlayController.windowLevel.rawValue + 1)
                    }
                }

            // Label above the control: inline, the full-width segments squeeze it to one letter per line.
            VStack(alignment: .leading, spacing: PK.Spacing.xs) {
                Text("Size")
                Picker("Size", selection: sizeBinding) {
                    ForEach(StrokeSize.allCases) { size in
                        Text(size.title).tag(size)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }
        }
        .padding(PK.Spacing.m)
        .frame(width: 200)
    }

    private var sizeBinding: Binding<StrokeSize> {
        Binding(get: { state.size }, set: { state.setSize($0) })
    }

    private var customColor: Binding<Color> {
        Binding(
            get: { Color(cgColor: state.color.cgColor) },
            set: { newValue in
                guard let srgb = NSColor(newValue).usingColorSpace(.sRGB) else { return }
                state.setColor(RGBAColor(red: srgb.redComponent, green: srgb.greenComponent, blue: srgb.blueComponent))
            }
        )
    }

    private static func name(of color: RGBAColor) -> String {
        switch color {
        case .red: "Red"
        case .orange: "Orange"
        case .yellow: "Yellow"
        case .green: "Green"
        case .blue: "Blue"
        case .purple: "Purple"
        case .black: "Black"
        case .white: "White"
        default: "Custom"
        }
    }
}

/// What the actions bar offers. Area picking (recording, scrolling capture)
/// replaces the output actions with a single confirm button.
enum ActionsBarStyle: Equatable {
    case output
    case confirm(title: String, symbol: String)
}

/// Horizontal actions bar under the selection (OUT-1…OUT-5, SC-13).
struct ActionsBar: View {
    let state: EditorState
    let style: ActionsBarStyle

    var body: some View {
        HStack(spacing: PK.Spacing.xxs) {
            switch style {
            case .output:
                action("Open in Editor", "macwindow.badge.plus", .openEditor, shortcut: "⌘E")
                action("Pin to Screen", "pin", .pin, shortcut: "⌥P")
                action("Share", "square.and.arrow.up", .share, shortcut: nil)
                action("Print", "printer", .print, shortcut: "⌘P")
                action("Copy", "doc.on.doc", .copy, shortcut: "⌘C")
                action("Save", "square.and.arrow.down", .save, shortcut: "⌘S")
                    .contextMenu {
                        Button("Save As…") { state.perform?(.saveAs) }
                    }
            case let .confirm(title, symbol):
                Button {
                    state.perform?(.confirmPick)
                } label: {
                    Label(title, systemImage: symbol)
                        .font(.callout.weight(.semibold))
                        .padding(.horizontal, PK.Spacing.s)
                        .frame(height: PK.Metrics.toolButton)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.regular)
                .help("\(title) — ↩")
            }

            Divider().frame(height: PK.Metrics.toolButton - PK.Spacing.s).padding(.horizontal, PK.Spacing.xxs)

            action("Close", "xmark", .close, shortcut: "esc")
        }
        .padding(PK.Spacing.xs)
        .pkSurface()
        .fixedSize()
    }

    private func action(_ title: String, _ symbol: String, _ command: EditorCommand, shortcut: String?) -> some View {
        Button {
            state.perform?(command)
        } label: {
            Label(title, systemImage: symbol).labelStyle(.iconOnly)
        }
        .buttonStyle(PKToolButtonStyle())
        .help(shortcut.map { "\(title) — \($0)" } ?? title)
    }
}
