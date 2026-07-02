import XCTest
import simd
@testable import MyPortrait

/// 相机变换 round-trip 单测 —— 调研点名的坑位(缩放锚点/平移一致性)。
final class GraphCameraTests: XCTestCase {

    let viewSize = CGSize(width: 800, height: 600)

    /// world → screen → world 恒等(任意 center/zoom)。
    func testRoundTrip() {
        var cam = GraphCamera()
        cam.center = SIMD2<Float>(123.4, -56.7)
        cam.zoom = 2.35
        let worlds: [SIMD2<Float>] = [
            .zero, SIMD2(300, 200), SIMD2(-451.2, 87.9), SIMD2(0.1, -9999),
        ]
        for w in worlds {
            let s = cam.worldToScreen(w, viewSize: viewSize)
            let back = cam.screenToWorld(s, viewSize: viewSize)
            XCTAssertEqual(back.x, w.x, accuracy: 0.01)
            XCTAssertEqual(back.y, w.y, accuracy: 0.01)
        }
    }

    /// zoom=1、center=0 时,世界原点落在视口中心。
    func testIdentityCenters() {
        let cam = GraphCamera()
        let s = cam.worldToScreen(.zero, viewSize: viewSize)
        XCTAssertEqual(s.x, 400, accuracy: 1e-9)
        XCTAssertEqual(s.y, 300, accuracy: 1e-9)
    }

    /// 锚点缩放:缩放后锚点处的世界坐标不动(点哪儿放大哪儿)。
    func testZoomKeepsAnchorFixed() {
        var cam = GraphCamera()
        cam.center = SIMD2<Float>(50, 80)
        cam.zoom = 1.2
        let anchor = CGPoint(x: 231, y: 470)
        let worldBefore = cam.screenToWorld(anchor, viewSize: viewSize)
        cam.zoom(by: 1.8, anchor: anchor, viewSize: viewSize)
        let worldAfter = cam.screenToWorld(anchor, viewSize: viewSize)
        XCTAssertEqual(worldAfter.x, worldBefore.x, accuracy: 0.05)
        XCTAssertEqual(worldAfter.y, worldBefore.y, accuracy: 0.05)
        XCTAssertEqual(cam.zoom, 1.2 * 1.8, accuracy: 1e-9)
    }

    /// 缩放钳制在 zoomRange 内,锚点性质仍保持。
    func testZoomClamped() {
        var cam = GraphCamera()
        cam.zoom(by: 1e9, anchor: CGPoint(x: 400, y: 300), viewSize: viewSize)
        XCTAssertEqual(cam.zoom, GraphCamera.zoomRange.upperBound, accuracy: 1e-9)
        cam.zoom(by: 1e-9, anchor: CGPoint(x: 0, y: 0), viewSize: viewSize)
        XCTAssertEqual(cam.zoom, GraphCamera.zoomRange.lowerBound, accuracy: 1e-9)
    }

    /// 平移:屏幕位移 delta → 内容跟着动 delta(视觉方向一致)。
    func testPanMovesContentWithPointer() {
        var cam = GraphCamera()
        cam.zoom = 2
        let w = SIMD2<Float>(10, 10)
        let before = cam.worldToScreen(w, viewSize: viewSize)
        cam.pan(byScreen: CGSize(width: 30, height: -12))
        let after = cam.worldToScreen(w, viewSize: viewSize)
        XCTAssertEqual(after.x - before.x, 30, accuracy: 0.01)
        XCTAssertEqual(after.y - before.y, -12, accuracy: 0.01)
    }
}
