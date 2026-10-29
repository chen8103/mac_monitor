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
        XCTAssertNil(ActivityCalculator.barFractions(for: nil))

        let low = ActivityCalculator.barFractions(for: TransferRates(inbound: 524_288, outbound: 262_144))
        XCTAssertEqual(low?.inbound ?? -1, 0.5, accuracy: 0.001)
        XCTAssertEqual(low?.outbound ?? -1, 0.25, accuracy: 0.001)

        let high = ActivityCalculator.barFractions(for: TransferRates(inbound: 8_388_608, outbound: 2_097_152))
        XCTAssertEqual(high?.inbound ?? -1, 1, accuracy: 0.001)
        XCTAssertEqual(high?.outbound ?? -1, 0.25, accuracy: 0.001)
    }

    func testFailedReadKeepsLastRateAndInvalidDeltaDoesNot() {
        var track = ActivityCalculator.Track()
        struct ReadFailure: Error {}
        XCTAssertNil(ActivityCalculator.advance(track: &track, now: 1) { throw ReadFailure() })

        let initial = TransferCounters(inbound: 1_000, outbound: 2_000)
        XCTAssertNil(ActivityCalculator.advance(track: &track, now: 10) { ["device": initial] })

        let next = TransferCounters(inbound: 1_124, outbound: 2_512)
        let rate = ActivityCalculator.advance(track: &track, now: 12) { ["device": next] }
        XCTAssertEqual(rate?.inbound ?? -1, 62, accuracy: 0.001)

        let kept = ActivityCalculator.advance(track: &track, now: 15) { throw ReadFailure() }
        XCTAssertEqual(kept?.inbound ?? -1, 62, accuracy: 0.001)
        XCTAssertEqual(track.previous?.counters, ["device": next])

        XCTAssertNil(ActivityCalculator.advance(track: &track, now: 16) {
            ["device": TransferCounters(inbound: 1_000, outbound: 2_000)]
        })
        XCTAssertEqual(track.lastRate?.inbound ?? -1, 62, accuracy: 0.001)

        let recovered = ActivityCalculator.advance(track: &track, now: 18) {
            ["device": TransferCounters(inbound: 1_100, outbound: 2_200)]
        }
        XCTAssertEqual(recovered?.inbound ?? -1, 50, accuracy: 0.001)
    }

    func testDeviceChangesDoNotCountHistoricalTraffic() {
        var track = ActivityCalculator.Track()
        let a = TransferCounters(inbound: 100, outbound: 200)
        let b = TransferCounters(inbound: 9_000_000_000, outbound: 6_000_000_000)
        XCTAssertNil(ActivityCalculator.advance(track: &track, now: 1) { ["a": a] })
        XCTAssertEqual(ActivityCalculator.advance(track: &track, now: 4) { ["a": a, "b": b] }, TransferRates(inbound: 0, outbound: 0))
        XCTAssertEqual(ActivityCalculator.advance(track: &track, now: 7) {
            ["a": TransferCounters(inbound: 400, outbound: 800)]
        }, TransferRates(inbound: 100, outbound: 200))
        XCTAssertEqual(ActivityCalculator.advance(track: &track, now: 10) {
            ["a": TransferCounters(inbound: 700, outbound: 1_400), "b": b]
        }, TransferRates(inbound: 100, outbound: 200))
        XCTAssertEqual(ActivityCalculator.advance(track: &track, now: 13) {
            ["a": TransferCounters(inbound: 1_000, outbound: 2_000),
             "b": TransferCounters(inbound: 9_000_000_600, outbound: 6_000_000_900)]
        }, TransferRates(inbound: 300, outbound: 500))
        XCTAssertNil(ActivityCalculator.advance(track: &track, now: 16) { ["c": b] })
    }

    func testRateFormatting() {
        XCTAssertEqual(MetricFormatting.rate(512), "512.0 B/s")
        XCTAssertEqual(MetricFormatting.rate(1_536), "1.5 KB/s")
        XCTAssertEqual(MetricFormatting.rate(2_621_440), "2.5 MB/s")
        XCTAssertEqual(MetricFormatting.rate(3_221_225_472), "3.0 GB/s")
    }
}
