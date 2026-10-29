import XCTest
@testable import MacMonitor

final class SystemMetricsSamplerTests: XCTestCase {
    func testUsedMemoryAddsOnlyActiveWiredAndCompressorPages() {
        XCTAssertEqual(
            SystemMetricsSampler.usedBytes(active: 10, wired: 20, compressor: 30, pageSize: 4096),
            245_760
        )
    }

    func testLiveSamplerReturnsPlausibleMetrics() async throws {
        let profile = try SystemMetricsSampler.readProfile()
        XCTAssertGreaterThan(profile.coreCount, 0)
        XCTAssertGreaterThan(profile.totalMemory, 0)
        XCTAssertFalse(profile.hostName.isEmpty)
        XCTAssertFalse(profile.darwinVersion.isEmpty)

        let actor = MetricsSamplingActor(profile: profile)
        let snapshot = try await actor.sample()
        XCTAssertNil(snapshot.cpuUsage)
        XCTAssertEqual(snapshot.loadAverages.count, 3)
        XCTAssertLessThanOrEqual(snapshot.usedMemory, snapshot.totalMemory)
    }

    func testLiveActivityCountersAndRates() async throws {
        let disk = try SystemMetricsSampler.readDiskCounters()
        let network = try SystemMetricsSampler.readNetworkCounters()
        XCTAssertGreaterThan(disk.inbound + disk.outbound, 0)
        XCTAssertGreaterThan(network.inbound + network.outbound, 0)

        let actor = MetricsSamplingActor(profile: SystemMetricsSampler.readProfile())
        let first = try await actor.sample()
        XCTAssertNil(first.diskActivity)
        XCTAssertNil(first.networkActivity)

        try await Task.sleep(for: .milliseconds(20))
        let second = try await actor.sample()
        XCTAssertNotNil(second.diskActivity)
        XCTAssertNotNil(second.networkActivity)
    }
}
