import SwiftUI

/// Chat 背景。原版是 Canvas + blur + screen blend + grain + cursor halo
/// 的「动态光晕」实现 —— hang sample 显示主线程 99% 卡在
/// CAContext.waitForCommitId,是这套 30fps 强制重绘的代价。
///
/// 现在退化成**纯静态蓝色渐变**:零动画、零 Canvas、零 blur,SwiftUI
/// 一次性 layer 化(.drawingGroup 不需要 —— LinearGradient 本来就是 GPU
/// 直绘)。前台不再永久烧主线程,背景态自然零开销。
struct AmbientBackground: View {
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        ZStack {
            if colorScheme == .light {
                // Light:奶白 → 浅薰衣草 → 浅蓝粉。柔和、温暖、不刺眼,
                // 配合 ultraThinMaterial 玻璃料质感更显高级。
                LinearGradient(
                    colors: [
                        Color(red: 0.98, green: 0.97, blue: 1.00),  // top-left:奶白
                        Color(red: 0.93, green: 0.93, blue: 0.99),  // mid:浅薰衣草
                        Color(red: 0.95, green: 0.92, blue: 0.97),  // bottom-right:浅蓝粉
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
                // 左上一个浅紫光晕,跟 sidebar 的 RadialGradient 同向呼应。
                RadialGradient(
                    colors: [Color(hue: 0.72, saturation: 0.45, brightness: 0.95).opacity(0.30), .clear],
                    center: .topLeading,
                    startRadius: 0, endRadius: 560
                )
                // 右下一个柔和蓝光,让画面有"光从远方倾入"的层次感。
                RadialGradient(
                    colors: [Color(hue: 0.58, saturation: 0.45, brightness: 0.95).opacity(0.18), .clear],
                    center: .bottomTrailing,
                    startRadius: 0, endRadius: 520
                )
            } else {
                LinearGradient(
                    colors: [
                        Color(red: 0.06, green: 0.10, blue: 0.22),
                        Color(red: 0.03, green: 0.05, blue: 0.13),
                        Color(red: 0.01, green: 0.02, blue: 0.05),
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            }
        }
        .ignoresSafeArea()
    }
}
