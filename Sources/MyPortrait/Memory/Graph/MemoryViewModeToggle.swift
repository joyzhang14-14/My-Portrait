import SwiftUI

/// Memories 区 text ⇄ canvas 模式切换钮(需求 §3.1)。
/// 自绘:两段各为「图标 + 文字」,选中段被一个圆角长方形框住,
/// 切换时用 spring 动画滑到另一段(matchedGeometryEffect)。
struct MemoryViewModeToggle: View {
    @Binding var mode: MemoryViewMode
    @Namespace private var selectionNS

    var body: some View {
        HStack(spacing: 4) {
            segment(.canvas, icon: "atom", label: "canvas")
            segment(.text, icon: "list.bullet", label: "text")
        }
    }

    private func segment(_ m: MemoryViewMode, icon: String, label: String) -> some View {
        let isOn = mode == m
        return Button {
            withAnimation(.spring(response: 0.32, dampingFraction: 0.78)) { mode = m }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: icon)
                    .font(.system(size: 11))
                Text(label)
                    .font(.system(size: 12, weight: isOn ? .semibold : .regular))
            }
            .foregroundStyle(isOn ? Theme.textPrimary : Theme.textSecondary)
            .padding(.horizontal, 14)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity)
            .background {
                if isOn {
                    // 选中段的圆角长方形框(用户 2026-07-01 定稿:比椭圆好看)
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Theme.accent.opacity(0.13))
                        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .strokeBorder(Theme.accent.opacity(0.7), lineWidth: 1.2))
                        .matchedGeometryEffect(id: "selection", in: selectionNS)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
