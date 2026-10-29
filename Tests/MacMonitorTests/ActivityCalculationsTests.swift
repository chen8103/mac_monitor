import XCTest
@testable import MacMonitor

final class ActivityCalculationsTests: XCTestCase {
    func testFirstActivitySampleIsUnavailable() {
        let current = TransferCounters(inbound: 100, outbound: 200)
        XCTAssertNil(ActivityCalculator.rates(previous: nil, current: current, elapsed: 3))
    }

    func testActivityRatesUseActualElapsedTime() {
        let previous = TransferCounters(inbound: 1_000, outbound: 2_000)
        let current = TransferCounters(inbound: 1_124, outbound: 2_512)
        let result = ActivityCalculator.rates(previous: previous, current: current, elapsed: 2)
        XCTAssertEqual(result?.inbound ?? 0, 62, accuracy: 0.001)
        XCTAssertEqual(result?.outbound ?? 0, 256, accuracy: 0.001)
    }

    func testInvalidActivityDeltasAreUnavailable() {
        let previous = TransferCounters(inbound: 100, outbound: 200)
        XCTAssertNil(ActivityCalculator.rates(previous: previous, current: previous, elapsed: 0))
        let regressed = TransferCounters(inbound: 101, outbound: 199)
        XCTAssertNil(ActivityCalculator.rates(previous: previous, current: regressed, elapsed: 1))
    }

    func testActivityBarFractionsUsePeakAndMinimumScale() {
        let empty = ActivityCalculator.barFractions(for: nil)
        XCTAssertEqual(empty.inbound, 0)
        XCTAssertEqual(empty.outbound, 0)

        let low = ActivityCalculator.barFractions(for: TransferRates(inbound: 524_288, outbound: 262_144))
        XCTAssertEqual(low.inbound, 0.5, accuracy: 0.001)
        XCTAssertEqual(low.outbound, 0.25, accuracy: 0.001)

        let high = ActivityCalculator.barFractions(for: TransferRates(inbound: 8_388_608, outbound: 2_097_152))
        XCTAssertEqual(high.inbound, 1)
        XCTAssertEqual(high.outbound, 0.25, accuracy: 0.001)
    }

    func testRateFormatting() {
        XCTAssertEqual(MetricFormatting.rate(512), "512.0 B/s")
        XCTAssertEqual(MetricFormatting.rate(1_536), "1.5 KB/s")
        XCTAssertEqual(MetricFormatting.rate(2_621_440), "2.5 MB/s")
        XCTAssertEqual(MetricFormatting.rate(3_221_225_472), "3.0 GB/s")
    }
}
