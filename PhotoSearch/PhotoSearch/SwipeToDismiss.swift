import SwiftUI

/// Photos-style interactive dismiss: drag the photo vertically to leave
/// full-screen. Runs *simultaneously* with the paging TabView, but only acts on
/// vertical-dominant drags so horizontal swipes still page between photos.
/// Disabled while zoomed (a drag should pan the zoomed image instead).
struct SwipeToDismiss: ViewModifier {
    @Environment(\.dismiss) private var dismiss
    let isEnabled: Bool

    @State private var translation: CGSize = .zero

    private var dragProgress: CGFloat {
        min(abs(translation.height) / 600, 1)
    }

    func body(content: Content) -> some View {
        content
            .scaleEffect(1 - dragProgress * 0.15)
            .offset(y: translation.height)
            .simultaneousGesture(
                DragGesture(minimumDistance: 15)
                    .onChanged { value in
                        guard isEnabled,
                              abs(value.translation.height) > abs(value.translation.width)
                        else { return }
                        translation = value.translation
                    }
                    .onEnded { value in
                        let shouldDismiss = isEnabled
                            && abs(value.translation.height) > 140
                            && abs(value.translation.height) > abs(value.translation.width)
                        if shouldDismiss {
                            dismiss()
                        } else {
                            withAnimation(.interactiveSpring(response: 0.3, dampingFraction: 0.8)) {
                                translation = .zero
                            }
                        }
                    }
            )
    }
}

extension View {
    func swipeToDismiss(isEnabled: Bool) -> some View {
        modifier(SwipeToDismiss(isEnabled: isEnabled))
    }
}
