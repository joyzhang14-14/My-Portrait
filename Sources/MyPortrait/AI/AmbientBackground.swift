import SwiftUI

/// Chat 背景。原版是 Canvas + blur + screen blend + grain + cursor halo
/// 的「动态光晕」实现 —— hang sample 显示主线程 99% 卡在
/// CAContext.waitForCommitId,是这套 30fps 强制重绘的代价。
///
/// 现在退化成**纯静态蓝色渐变**:零动画、零 Canvas、零 blur,SwiftUI
/// 一次性 layer 化(.drawingGroup 不需要 —— LinearGradient 本来就是 GPU
/// 直绘)。前台不再永久烧主线程,背景态自然零开销。
struct AmbientBackground: View {
    var body: some View {
        LinearGradient(
            colors: [
                Color(red: 0.06, green: 0.10, blue: 0.22),   // top-left:深海军蓝
                Color(red: 0.03, green: 0.05, blue: 0.13),   // mid:更深
                Color(red: 0.01, green: 0.02, blue: 0.05),   // bottom-right:几近黑
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
        .ignoresSafeArea()
    }
}
