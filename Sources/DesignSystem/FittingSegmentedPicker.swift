import SwiftUI

/// A segmented picker that falls back to a menu when its segments don't fit.
///
/// A segmented control never shrinks below its intrinsic size. In a fixed-width
/// panel it overflows the row instead, and the leading segments are clipped.
/// The system draws segments larger on newer releases, so a picker that fits
/// today can overflow on the next one. Use this in fixed-width panels.
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
        ViewThatFits(in: .horizontal) {
            Picker(title, selection: $selection, content: content)
                .pickerStyle(.segmented)
            Picker(title, selection: $selection, content: content)
                .pickerStyle(.menu)
        }
    }
}
