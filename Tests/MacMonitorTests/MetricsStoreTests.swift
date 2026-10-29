import XCTest
@testable import MacMonitor

private enum TestError: Error {
    case sample
}

private actor MetricsFake: MetricsSampling {
    let systemProfile: SystemProfile
    private var results: [Result<MetricsSnapshot, Error>]
    private(set) var profileCallCount = 0
    private(set) var sampleCallCount = 0

    init(profile: SystemProfile, results: [Result<MetricsSnapshot, Error>]) {
        systemProfile = profile
        self.results = results
    }

    func profile() async -> SystemProfile {
        profileCallCount += 1
        return systemProfile
    }

    func sample() async throws -> MetricsSnapshot {
        sampleCallCount += 1
        let result = results.count > 1 ? results.removeFirst() : results[0]
        return try result.get()
    }
}

@MainActor
final class MetricsStoreTests: XCTestCase {
    let profile = SystemProfile(hostName: "test-mac", coreCount: 2, darwinVersion: "test", architecture: "arm64", totalMemory: 1024)
    let snapshot = MetricsSnapshot(uptime: 60, cpuUsage: 25, coreUsage: [20, 30], loadAverages: [1, 2, 3], usedMemory: 256, totalMemory: 1024)

    func testStartIsIdempotent() async {
        let fake = MetricsFake(profile: profile, results: [.success(snapshot)])
        let store = MetricsStore(providerFactory: { fake }, sleep: { try await Task.sleep(for: .seconds(60)) })
        store.start()
        store.start()
        await Task.yield()
        store.stop()
        let count = await fake.profileCallCount
        XCTAssertEqual(count, 1)
    }

    func testFailureKeepsLastSnapshotAndNextSuccessClearsError() async throws {
        let fake = MetricsFake(profile: profile, results: [.success(snapshot), .failure(TestError.sample), .success(snapshot)])
        let store = MetricsStore(providerFactory: { fake }, sleep: { try await Task.sleep(for: .milliseconds(1)) })
        store.start()
        try await Task.sleep(for: .milliseconds(30))
        store.stop()
        XCTAssertEqual(store.snapshot, snapshot)
        XCTAssertNil(store.errorMessage)
        let count = await fake.sampleCallCount
        XCTAssertGreaterThanOrEqual(count, 3)
    }

    func testStopPreventsAdditionalSamples() async throws {
        let fake = MetricsFake(profile: profile, results: [.success(snapshot)])
        let store = MetricsStore(providerFactory: { fake }, sleep: { try await Task.sleep(for: .seconds(60)) })
        store.start()
        try await Task.sleep(for: .milliseconds(10))
        store.stop()
        let stoppedCount = await fake.sampleCallCount
        try await Task.sleep(for: .milliseconds(10))
        let finalCount = await fake.sampleCallCount
        XCTAssertEqual(finalCount, stoppedCount)
    }
}
