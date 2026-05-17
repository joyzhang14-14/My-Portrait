import SwiftUI

/// Floating context chip rendered above the input field (and again, smaller,
/// on the user's chat bubble). Subtle gradient border + glass fill, click ×
/// to remove. On the chat bubble we render without the close button.
struct ContextChipView: View {
    let chip: ContextChip
    var onRemove: (() -> Void)? = nil
    var compact: Bool = false

    @State private var hover = false

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: chip.icon)
                .font(.system(size: compact ? 9 : 10, weight: .semibold))
                .foregroundStyle(.white.opacity(0.85))
            Text(chip.label)
                .font(.system(size: compact ? 10 : 11, weight: .medium, design: .monospaced))
                .foregroundStyle(.white.opacity(0.92))
            if onRemove != nil {
                Button(action: { onRemove?() }) {
                    Image(systemName: "xmark")
                        .font(.system(size: 8.5, weight: .bold))
                        .foregroundStyle(.white.opacity(hover ? 0.95 : 0.55))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, compact ? 7 : 8)
        .padding(.vertical, compact ? 3 : 4.5)
        .background(
            Capsule()
                .fill(.ultraThinMaterial)
                .overlay(
                    Capsule()
                        .strokeBorder(
                            LinearGradient(
                                colors: [Color.purple.opacity(0.60), Color.blue.opacity(0.45)],
                                startPoint: .topLeading, endPoint: .bottomTrailing
                            ),
                            lineWidth: 0.9
                        )
                )
                .shadow(color: Color.purple.opacity(0.18), radius: hover ? 8 : 4, x: 0, y: 2)
        )
        .scaleEffect(hover ? 1.04 : 1.0)
        .onHover { hover = $0 }
        .animation(.easeOut(duration: 0.15), value: hover)
    }
}
