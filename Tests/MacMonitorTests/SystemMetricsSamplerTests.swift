import Darwin
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
        XCTAssertEqual(snapshot.coreUsage.count, profile.coreCount)
        XCTAssertTrue(snapshot.coreUsage.allSatisfy { $0 == nil })
        XCTAssertEqual(snapshot.loadAverages.count, 3)
        XCTAssertLessThanOrEqual(snapshot.usedMemory, snapshot.totalMemory)
    }

    func testNetworkCountersKeep64BitTotalsAndSkipInactiveInterfaces() throws {
        let active = UInt32(IFF_UP | IFF_RUNNING)
        let counters = try SystemMetricsSampler.networkCounters(from: [
            NetworkInterfaceCounters(id: "en0", flags: active, received: 5_000_000_000, sent: 7_000_000_000),
            NetworkInterfaceCounters(id: "en1", flags: active, received: 1_000, sent: 50),
            NetworkInterfaceCounters(id: "lo0", flags: active | UInt32(IFF_LOOPBACK), received: 9_000_000_000, sent: 9),
            NetworkInterfaceCounters(id: "en2", flags: UInt32(IFF_UP), received: 9_000_000_000, sent: 9)
        ])
        XCTAssertEqual(counters["en0"]?.inbound, 5_000_000_000)
        XCTAssertEqual(counters["en0"]?.outbound, 7_000_000_000)
        XCTAssertEqual(Set(counters.keys), Set(["en0", "en1"]))
        XCTAssertTrue(try SystemMetricsSampler.networkCounters(from: []).isEmpty)
    }

    func testAllInterfacesStoppingClearsBaselineBeforeReconnect() throws {
        let active = UInt32(IFF_UP | IFF_RUNNING)
        let online = try SystemMetricsSampler.networkCounters(from: [
            NetworkInterfaceCounters(id: "en0", flags: active, received: 1_000, sent: 2_000)
        ])
        let offline = try SystemMetricsSampler.networkCounters(from: [
            NetworkInterfaceCounters(id: "en0", flags: 0, received: 1_000, sent: 2_000)
        ])
        var track = ActivityCalculator.Track()
        _ = ActivityCalculator.advance(track: &track, now: 1) { online }
        XCTAssertNotNil(ActivityCalculator.advance(track: &track, now: 4) { online })
        XCTAssertNil(ActivityCalculator.advance(track: &track, now: 7) { offline })
        XCTAssertNil(ActivityCalculator.advance(track: &track, now: 10) { online })
        XCTAssertEqual(ActivityCalculator.advance(track: &track, now: 13) { online }, TransferRates(inbound: 0, outbound: 0))
    }

    func testPartialNetworkReadPreservesRateAndBaseline() {
        struct ReadFailure: Error {}
        let active = UInt32(IFF_UP | IFF_RUNNING)
        var track = ActivityCalculator.Track()
        _ = ActivityCalculator.advance(track: &track, now: 1) {
            ["en0": TransferCounters(inbound: 100, outbound: 200)]
        }
        let last = ActivityCalculator.advance(track: &track, now: 3) {
            ["en0": TransferCounters(inbound: 300, outbound: 600)]
        }
        let saved = track.previous
        var visited: [UInt32] = []
        let kept = ActivityCalculator.advance(track: &track, now: 5) {
            try SystemMetricsSampler.networkCounters(indices: [1, 7]) { index in
                visited.append(index)
                if index == 7 { throw ReadFailure() }
                return NetworkInterfaceCounters(id: "en0", flags: active, received: 500, sent: 1_000)
            }
        }
        XCTAssertEqual(visited, [1, 7])
        XCTAssertEqual(kept, last)
        XCTAssertEqual(track.previous, saved)
        XCTAssertEqual(ActivityCalculator.advance(track: &track, now: 7) {
            ["en0": TransferCounters(inbound: 700, outbound: 1_400)]
        }, TransferRates(inbound: 100, outbound: 200))
    }

    func testLiveActivityCountersAndRates() async throws {
        let disk = try SystemMetricsSampler.readDiskCounters()
        let network = try SystemMetricsSampler.readNetworkCounters()
        XCTAssertTrue(disk.values.contains { $0.inbound > 0 || $0.outbound > 0 })
        XCTAssertTrue(network.values.contains { $0.inbound > 0 || $0.outbound > 0 })

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
