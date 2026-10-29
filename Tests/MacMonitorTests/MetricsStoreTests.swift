import Foundation
import XCTest
@testable import MacMonitor

private enum TestError: Error {
    case sample
}

private final class RetryGate: @unchecked Sendable {
    var allow = false
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

// One-shot rendezvous: values are retained if sent before the waiter arrives.
// Deliberately ignores cancellation to model a provider finishing obsolete work.
private actor StoreTestSignal<Value: Sendable> {
    private var value: Value?
    private var waiters: [CheckedContinuation<Value, Never>] = []

    func wait() async -> Value {
        if let value { return value }
        return await withCheckedContinuation { waiters.append($0) }
    }

    func send(_ value: Value) {
        precondition(self.value == nil)
        self.value = value
        let pending = waiters
        waiters.removeAll()
        for waiter in pending { waiter.resume(returning: value) }
    }
}

private final class ControlledMetricsProvider: MetricsSampling {
    private let readProfile: @Sendable () async -> SystemProfile
    private let readSample: @Sendable () async throws -> MetricsSnapshot
    private let finished: StoreTestSignal<Void>

    init(
        profile: @escaping @Sendable () async -> SystemProfile,
        sample: @escaping @Sendable () async throws -> MetricsSnapshot,
        finished: StoreTestSignal<Void>
    ) {
        readProfile = profile
        readSample = sample
        self.finished = finished
    }

    func profile() async -> SystemProfile { await readProfile() }
    func sample() async throws -> MetricsSnapshot { try await readSample() }

    deinit {
        // The factory never retains this provider. Its release acknowledges that
        // the store has finished consuming the old operation's result.
        let finished = finished
        Task { await finished.send(()) }
    }
}

private final class StoreTestProviderFactory: @unchecked Sendable {
    private let lock = NSLock()
    private var factories: [@Sendable () -> any MetricsSampling]

    init(_ factories: [@Sendable () -> any MetricsSampling]) {
        self.factories = factories
    }

    func make() -> any MetricsSampling {
        lock.lock()
        defer { lock.unlock() }
        return factories.removeFirst()()
    }
}

private actor StoreTestSleeper {
    private var operations: [@Sendable () async throws -> Void]

    init(_ operations: [@Sendable () async throws -> Void]) {
        self.operations = operations
    }

    func sleep() async throws {
        let operation = operations.removeFirst()
        try await operation()
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
        for _ in 0 ..< 50 {
            if await fake.profileCallCount > 0 { break }
            await Task.yield()
        }
        store.stop()
        let count = await fake.profileCallCount
        XCTAssertEqual(count, 1)
    }

    func testFailureKeepsLastSnapshotAndNextSuccessClearsError() async throws {
        let fake = MetricsFake(profile: profile, results: [.success(snapshot), .failure(TestError.sample), .success(snapshot)])
        let store = MetricsStore(providerFactory: { fake }, sleep: { try await Task.sleep(for: .milliseconds(1)) })
        store.start()
        for _ in 0 ..< 100 {
            if await fake.sampleCallCount >= 3 { break }
            try await Task.sleep(for: .milliseconds(1))
        }
        store.stop()
        XCTAssertEqual(store.snapshot, snapshot)
        XCTAssertNil(store.errorMessage)
        let count = await fake.sampleCallCount
        XCTAssertGreaterThanOrEqual(count, 3)
    }

    func testStartRetriesAfterRefreshLoopExits() async {
        let gate = RetryGate()
        let fake = MetricsFake(profile: profile, results: [.success(snapshot)])
        let store = MetricsStore(
            providerFactory: {
                guard gate.allow else { throw TestError.sample }
                return fake
            },
            sleep: { try await Task.sleep(for: .seconds(60)) }
        )
        store.start()
        for _ in 0 ..< 100 {
            if store.errorMessage != nil { break }
            await Task.yield()
        }
        XCTAssertNotNil(store.errorMessage)
        await Task.yield()
        gate.allow = true
        store.start()
        for _ in 0 ..< 100 {
            if store.snapshot == snapshot { break }
            await Task.yield()
        }
        store.stop()
        XCTAssertEqual(store.snapshot, snapshot)
        XCTAssertNil(store.errorMessage)
    }

    func testCancelledSampleFailureCannotOverwriteRestartedSuccess() async {
        let oldSampleStarted = StoreTestSignal<Void>()
        let releaseOldSample = StoreTestSignal<Void>()
        let oldFinished = StoreTestSignal<Void>()
        let newPublished = StoreTestSignal<Void>()
        let releaseNewSleep = StoreTestSignal<Void>()
        let newFinished = StoreTestSignal<Void>()
        let expectedProfile = profile
        let expectedSnapshot = snapshot
        let factory = StoreTestProviderFactory([
            {
                ControlledMetricsProvider(
                    profile: { expectedProfile },
                    sample: {
                        await oldSampleStarted.send(())
                        await releaseOldSample.wait()
                        throw TestError.sample
                    },
                    finished: oldFinished
                )
            },
            {
                ControlledMetricsProvider(
                    profile: { expectedProfile },
                    sample: { expectedSnapshot },
                    finished: newFinished
                )
            }
        ])
        let store = MetricsStore(providerFactory: { factory.make() }, sleep: {
            // The old implementation reaches sleep after publishing its error.
            if Task.isCancelled { throw CancellationError() }
            await newPublished.send(())
            await releaseNewSleep.wait()
            throw CancellationError()
        })

        store.start()
        await oldSampleStarted.wait()
        store.stop()
        store.start()
        await newPublished.wait()
        XCTAssertEqual(store.snapshot, expectedSnapshot)
        XCTAssertNil(store.errorMessage)

        await releaseOldSample.send(())
        await oldFinished.wait()
        XCTAssertEqual(store.profile, expectedProfile)
        XCTAssertEqual(store.snapshot, expectedSnapshot)
        XCTAssertNil(store.errorMessage)

        store.stop()
        await releaseNewSleep.send(())
        await newFinished.wait()
    }

    func testCancelledProfileCannotOverwriteRestartedProfile() async {
        let oldProfileStarted = StoreTestSignal<Void>()
        let releaseOldProfile = StoreTestSignal<Void>()
        let oldFinished = StoreTestSignal<Void>()
        let newPublished = StoreTestSignal<Void>()
        let releaseNewSleep = StoreTestSignal<Void>()
        let newFinished = StoreTestSignal<Void>()
        let oldProfile = SystemProfile(hostName: "obsolete-mac", coreCount: 1, darwinVersion: "old", architecture: "arm64", totalMemory: 512)
        let expectedProfile = profile
        let expectedSnapshot = snapshot
        let factory = StoreTestProviderFactory([
            {
                ControlledMetricsProvider(
                    profile: {
                        await oldProfileStarted.send(())
                        await releaseOldProfile.wait()
                        return oldProfile
                    },
                    sample: { expectedSnapshot },
                    finished: oldFinished
                )
            },
            {
                ControlledMetricsProvider(
                    profile: { expectedProfile },
                    sample: { expectedSnapshot },
                    finished: newFinished
                )
            }
        ])
        let store = MetricsStore(providerFactory: { factory.make() }, sleep: {
            if Task.isCancelled { throw CancellationError() }
            await newPublished.send(())
            await releaseNewSleep.wait()
            throw CancellationError()
        })

        store.start()
        await oldProfileStarted.wait()
        store.stop()
        store.start()
        await newPublished.wait()
        XCTAssertEqual(store.profile, expectedProfile)
        XCTAssertEqual(store.snapshot, expectedSnapshot)

        await releaseOldProfile.send(())
        await oldFinished.wait()
        XCTAssertEqual(store.profile, expectedProfile)
        XCTAssertEqual(store.snapshot, expectedSnapshot)
        XCTAssertNil(store.errorMessage)

        store.stop()
        await releaseNewSleep.send(())
        await newFinished.wait()
    }

    func testCancelledSleepFailureCannotOverwriteRestartedSuccess() async {
        let oldSleepStarted = StoreTestSignal<Void>()
        let releaseOldSleep = StoreTestSignal<Void>()
        let oldFinished = StoreTestSignal<Void>()
        let newPublished = StoreTestSignal<Void>()
        let releaseNewSleep = StoreTestSignal<Void>()
        let newFinished = StoreTestSignal<Void>()
        let expectedProfile = profile
        let expectedSnapshot = snapshot
        let factory = StoreTestProviderFactory([
            {
                ControlledMetricsProvider(
                    profile: { expectedProfile },
                    sample: { expectedSnapshot },
                    finished: oldFinished
                )
            },
            {
                ControlledMetricsProvider(
                    profile: { expectedProfile },
                    sample: { expectedSnapshot },
                    finished: newFinished
                )
            }
        ])
        let sleeper = StoreTestSleeper([
            {
                await oldSleepStarted.send(())
                await releaseOldSleep.wait()
                throw TestError.sample
            },
            {
                await newPublished.send(())
                await releaseNewSleep.wait()
                throw CancellationError()
            }
        ])
        let store = MetricsStore(providerFactory: { factory.make() }, sleep: { try await sleeper.sleep() })

        store.start()
        await oldSleepStarted.wait()
        store.stop()
        store.start()
        await newPublished.wait()
        XCTAssertEqual(store.snapshot, expectedSnapshot)
        XCTAssertNil(store.errorMessage)

        await releaseOldSleep.send(())
        await oldFinished.wait()
        XCTAssertEqual(store.profile, expectedProfile)
        XCTAssertEqual(store.snapshot, expectedSnapshot)
        XCTAssertNil(store.errorMessage)

        store.stop()
        await releaseNewSleep.send(())
        await newFinished.wait()
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
