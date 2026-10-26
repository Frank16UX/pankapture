import SwiftUI

/// A segmented picker that steps down to the small control size when its
/// segments don't fit.
///
/// A segmented control never shrinks below its minimum size. In a fixed-width
/// panel it overflows the row instead, and the card clips the outer segments.
/// The system draws segments larger on newer releases, so a picker that fits
/// today can overflow on the next one. The small size is about 15% narrower
/// and keeps every option visible (a menu would hide them). Use this in
/// fixed-width panels.
public struct FittingSegmentedPicker<Value: Hashable, Content: View>: View {
    private let title: String
    @Binding private var selection: Value
    private let content: () -> Content

    public init(_ title: String, selection: Binding<Value>, @ViewBuilder content: @escaping () -> Content) {
        self.title = title
        _selection = selection
        self.content = content
    }

    public var body: some View {
        // Only the bare control is measured: a whole form row reports an
        // unbounded ideal width, so it would never fit. The last choice is used
        // even when it doesn't fit; the small size can still give up some
        // padding, so it stays inside the row.
        LabeledContent(title) {
            ViewThatFits(in: .horizontal) {
                picker
                picker.controlSize(.small)
            }
        }
    }

    private var picker: some View {
        Picker(title, selection: $selection, content: content)
            .pickerStyle(.segmented)
            .labelsHidden()
    }
}
