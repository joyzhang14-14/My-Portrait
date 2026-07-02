import Foundation
import simd

/// 世界坐标 ⇄ 屏幕坐标。世界与屏幕同为 y 向下,不做翻转(少一个经典坑)。
/// screen = (world − center) × zoom + viewSize/2
struct GraphCamera: Equatable {
    /// 视口中心对准的世界坐标
    var center: SIMD2<Float> = .zero
    var zoom: Double = 1.0

    static let zoomRange: ClosedRange<Double> = 0.08...6.0

    func worldToScreen(_ w: SIMD2<Float>, viewSize: CGSize) -> CGPoint {
        CGPoint(x: (Double(w.x) - Double(center.x)) * zoom + viewSize.width / 2,
                y: (Double(w.y) - Double(center.y)) * zoom + viewSize.height / 2)
    }

    func screenToWorld(_ s: CGPoint, viewSize: CGSize) -> SIMD2<Float> {
        SIMD2<Float>(Float((s.x - viewSize.width / 2) / zoom + Double(center.x)),
                     Float((s.y - viewSize.height / 2) / zoom + Double(center.y)))
    }

    /// 平移:屏幕位移 delta(pt)→ 世界位移 delta/zoom。
    mutating func pan(byScreen delta: CGSize) {
        center.x -= Float(delta.width / zoom)
        center.y -= Float(delta.height / zoom)
    }

    /// 锚点缩放:缩放后 anchor 处的世界点仍停在 anchor 屏幕位置。
    mutating func zoom(by factor: Double, anchor: CGPoint, viewSize: CGSize) {
        let worldAtAnchor = screenToWorld(anchor, viewSize: viewSize)
        zoom = min(max(zoom * factor, Self.zoomRange.lowerBound), Self.zoomRange.upperBound)
        // 反解 center,使 worldAtAnchor 投影回 anchor
        center = SIMD2<Float>(
            Float(Double(worldAtAnchor.x) - (anchor.x - viewSize.width / 2) / zoom),
            Float(Double(worldAtAnchor.y) - (anchor.y - viewSize.height / 2) / zoom))
    }
}
