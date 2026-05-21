import XCTest
@testable import MyPortrait

final class WeightEMATests: XCTestCase {

    /// 0 天 → 不衰减；stored 原样返回。
    func testNoDecayAtZeroDays() {
        let ema = WeightEMA(halfLifeDays: 180)
        XCTAssertEqual(ema.currentWeight(stored: 1.0, daysSinceModified: 0), 1.0, accuracy: 1e-9)
        XCTAssertEqual(ema.currentWeight(stored: 7.5, daysSinceModified: 0), 7.5, accuracy: 1e-9)
    }

    /// 正好一个半衰期 → 减半。
    func testHalvesAfterOneHalfLife() {
        let ema = WeightEMA(halfLifeDays: 180)
        XCTAssertEqual(ema.currentWeight(stored: 1.0, daysSinceModified: 180), 0.5, accuracy: 1e-9)
        XCTAssertEqual(ema.currentWeight(stored: 4.0, daysSinceModified: 180), 2.0, accuracy: 1e-9)
    }

    /// 两个半衰期 → 1/4。
    func testQuarterAfterTwoHalfLives() {
        let ema = WeightEMA(halfLifeDays: 90)
        XCTAssertEqual(ema.currentWeight(stored: 1.0, daysSinceModified: 180), 0.25, accuracy: 1e-9)
    }

    /// 负 days 防御性截断到 0（不应放大）。
    func testNegativeDaysClampedToZero() {
        let ema = WeightEMA(halfLifeDays: 180)
        XCTAssertEqual(ema.currentWeight(stored: 1.0, daysSinceModified: -5), 1.0, accuracy: 1e-9)
    }

    /// halfLife = 0 防御：不衰减，原样返回（避免除零 / NaN）。
    func testZeroHalfLifeReturnsStored() {
        let ema = WeightEMA(halfLifeDays: 0)
        XCTAssertEqual(ema.currentWeight(stored: 3.0, daysSinceModified: 999), 3.0, accuracy: 1e-9)
    }

    /// afterMerge = currentWeight(...) + 1。
    func testAfterMerge() {
        let ema = WeightEMA(halfLifeDays: 180)
        // 0 天：1.0 + 1 = 2.0
        XCTAssertEqual(ema.afterMerge(stored: 1.0, daysSinceModified: 0), 2.0, accuracy: 1e-9)
        // 180 天：1.0×0.5 + 1 = 1.5
        XCTAssertEqual(ema.afterMerge(stored: 1.0, daysSinceModified: 180), 1.5, accuracy: 1e-9)
    }
}
