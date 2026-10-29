import XCTest
@testable import MacMonitor

final class MetricCalculationsTests: XCTestCase {
    func testFirstCPUSampleIsUnavailable() {
        XCTAssertNil(CPUCalculator.usage(previous: nil, current: [CPUTicks(user: 1, system: 1, idle: 1, nice: 0)]))
    }

    func testCPUDeltaCalculatesTotalAndCores() {
        let previous = [CPUTicks(user: 10, system: 10, idle: 80, nice: 0)]
        let current = [CPUTicks(user: 20, system: 20, idle: 140, nice: 0)]
        let result = CPUCalculator.usage(previous: previous, current: current)
        XCTAssertEqual(result?.total ?? 0, 25, accuracy: 0.001)
        XCTAssertEqual(result?.cores.first ?? 0, 25, accuracy: 0.001)
    }

    func testInvalidCPUDeltasAreUnavailable() {
        let tick = CPUTicks(user: 10, system: 10, idle: 10, nice: 0)
        XCTAssertNil(CPUCalculator.usage(previous: [tick], current: [tick]))
        XCTAssertNil(CPUCalculator.usage(previous: [tick], current: []))
        XCTAssertNil(CPUCalculator.usage(previous: [tick], current: [tick, tick]))
        XCTAssertNil(CPUCalculator.usage(previous: [tick], current: [CPUTicks(user: 9, system: 10, idle: 10, nice: 0)]))
    }

    func testThresholdBoundaries() {
        XCTAssertEqual(LoadLevel.cpu(69.9), .normal)
        XCTAssertEqual(LoadLevel.cpu(70), .warning)
        XCTAssertEqual(LoadLevel.cpu(90), .critical)
        XCTAssertEqual(LoadLevel.memory(79.9), .normal)
        XCTAssertEqual(LoadLevel.memory(80), .warning)
        XCTAssertEqual(LoadLevel.memory(90), .critical)
    }

    func testFormatting() {
        XCTAssertEqual(MetricFormatting.gibibytes(34_359_738_368), "32.0")
        XCTAssertEqual(MetricFormatting.uptime(90_061), "1d 1h 1m")
        XCTAssertEqual(MetricFormatting.uptime(3_661), "1h 1m")
        XCTAssertEqual(MetricFormatting.uptime(125), "2m")
        XCTAssertEqual(MetricFormatting.percent(23.44), "23.4%")
    }
}
