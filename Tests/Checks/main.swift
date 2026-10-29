import Darwin
import Foundation

func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    if !condition() {
        print("FAIL: \(message)")
        fflush(stdout)
        exit(1)
    }
}

func pass(_ message: String) {
    print("PASS: \(message)")
    fflush(stdout)
}

func expectEqual<T: Equatable>(_ actual: T, _ expected: T, _ message: String) {
    expect(actual == expected, "\(message): expected \(expected), got \(actual)")
}

func checkActivityCalculations() {
    let previous = TransferCounters(inbound: 1_000, outbound: 2_000)
    let current = TransferCounters(inbound: 1_124, outbound: 2_512)
    expect(ActivityCalculator.rates(previous: nil, current: current, elapsed: 3) == nil, "first activity sample")

    let rates = ActivityCalculator.rates(previous: previous, current: current, elapsed: 2)
    expect(abs((rates?.inbound ?? -1) - 62) < 0.001, "inbound rate")
    expect(abs((rates?.outbound ?? -1) - 256) < 0.001, "outbound rate")
    expect(ActivityCalculator.rates(previous: previous, current: previous, elapsed: 0) == nil, "zero activity interval")
    let regressed = TransferCounters(inbound: 1_125, outbound: 1_999)
    expect(ActivityCalculator.rates(previous: previous, current: regressed, elapsed: 1) == nil, "regressed activity counter")

    expect(ActivityCalculator.barFractions(for: nil) == nil, "unavailable activity bars")
    let lowBars = ActivityCalculator.barFractions(for: TransferRates(inbound: 524_288, outbound: 262_144))
    expect(abs((lowBars?.inbound ?? -1) - 0.5) < 0.001, "minimum-scale inbound bar")
    expect(abs((lowBars?.outbound ?? -1) - 0.25) < 0.001, "minimum-scale outbound bar")
    let highBars = ActivityCalculator.barFractions(for: TransferRates(inbound: 8_388_608, outbound: 2_097_152))
    expect(abs((highBars?.inbound ?? -1) - 1) < 0.001, "peak inbound bar")
    expect(abs((highBars?.outbound ?? -1) - 0.25) < 0.001, "relative outbound bar")
    checkActivityRetention()
    checkDeviceChanges()

    expectEqual(MetricFormatting.rate(512), "512.0 B/s", "B/s formatting")
    expectEqual(MetricFormatting.rate(1_536), "1.5 KB/s", "KB/s formatting")
    expectEqual(MetricFormatting.rate(2_621_440), "2.5 MB/s", "MB/s formatting")
    expectEqual(MetricFormatting.rate(3_221_225_472), "3.0 GB/s", "GB/s formatting")
}

func checkMetricCalculations() {
    checkActivityCalculations()
    let tick = CPUTicks(user: 10, system: 10, idle: 10, nice: 0)
    expect(CPUCalculator.usage(previous: nil, current: [tick]) == nil, "first CPU sample must be unavailable")

    let previous = [CPUTicks(user: 10, system: 10, idle: 80, nice: 0)]
    let current = [CPUTicks(user: 20, system: 20, idle: 140, nice: 0)]
    let usage = CPUCalculator.usage(previous: previous, current: current)
    expect(abs((usage?.total ?? -1) - 25) < 0.001, "total CPU delta")
    expect(abs((usage?.cores[0] ?? -1) - 25) < 0.001, "per-core CPU delta")

    let mixed = CPUCalculator.usage(previous: [tick, previous[0]], current: [tick, current[0]])
    expectEqual(mixed?.cores[0], nil, "zero-delta core must be unavailable, not idle")
    expectEqual(mixed?.cores[1], 25, "valid core remains available")
    expectEqual(mixed?.total, 25, "total uses valid elapsed ticks")

    expect(CPUCalculator.usage(previous: [tick], current: [tick]) == nil, "zero CPU delta")
    expect(CPUCalculator.usage(previous: [tick], current: []) == nil, "missing CPU core")
    expect(CPUCalculator.usage(previous: [tick], current: [tick, tick]) == nil, "changed CPU core count")
    expect(CPUCalculator.usage(previous: [tick], current: [CPUTicks(user: 9, system: 10, idle: 10, nice: 0)]) == nil, "regressed CPU counter")

    expectEqual(LoadLevel.cpu(69.9), .normal, "CPU below warning")
    expectEqual(LoadLevel.cpu(70), .warning, "CPU warning boundary")
    expectEqual(LoadLevel.cpu(90), .critical, "CPU critical boundary")
    expectEqual(LoadLevel.memory(79.9), .normal, "memory below warning")
    expectEqual(LoadLevel.memory(80), .warning, "memory warning boundary")
    expectEqual(LoadLevel.memory(90), .critical, "memory critical boundary")

    expectEqual(MetricFormatting.gibibytes(34_359_738_368), "32.0", "GiB formatting")
    expectEqual(MetricFormatting.uptime(90_061), "1d 1h 1m", "day uptime")
    expectEqual(MetricFormatting.uptime(3_661), "1h 1m", "hour uptime")
    expectEqual(MetricFormatting.uptime(125), "2m", "minute uptime")
    expectEqual(MetricFormatting.percent(23.44), "23.4%", "percentage formatting")
}

func checkActivityRetention() {
    var track = ActivityCalculator.Track()
    struct ReadFailure: Error {}
    expect(ActivityCalculator.advance(track: &track, now: 1) { throw ReadFailure() } == nil, "failed first read")

    let initial = TransferCounters(inbound: 1_000, outbound: 2_000)
    expect(ActivityCalculator.advance(track: &track, now: 10) { ["device": initial] } == nil, "first tracked sample")
    let next = TransferCounters(inbound: 1_124, outbound: 2_512)
    let rate = ActivityCalculator.advance(track: &track, now: 12) { ["device": next] }
    expect(abs((rate?.inbound ?? -1) - 62) < 0.001, "tracked inbound rate")

    let kept = ActivityCalculator.advance(track: &track, now: 15) { throw ReadFailure() }
    expect(abs((kept?.inbound ?? -1) - 62) < 0.001, "failed read keeps last rate")
    expect(track.previous?.counters == ["device": next], "failed read keeps previous counters")

    expect(ActivityCalculator.advance(track: &track, now: 16) {
        ["device": TransferCounters(inbound: 1_000, outbound: 2_000)]
    } == nil, "regressed activity sample")
    expect(abs((track.lastRate?.inbound ?? -1) - 62) < 0.001, "regression keeps last good rate")
    let recovered = ActivityCalculator.advance(track: &track, now: 18) {
        ["device": TransferCounters(inbound: 1_100, outbound: 2_200)]
    }
    expect(abs((recovered?.inbound ?? -1) - 50) < 0.001, "rate resumes from new baseline")
}

func checkDeviceChanges() {
    var track = ActivityCalculator.Track()
    let a = TransferCounters(inbound: 100, outbound: 200)
    let b = TransferCounters(inbound: 9_000_000_000, outbound: 6_000_000_000)
    expect(ActivityCalculator.advance(track: &track, now: 1) { ["a": a] } == nil, "first device baseline")
    expectEqual(ActivityCalculator.advance(track: &track, now: 4) { ["a": a, "b": b] }, TransferRates(inbound: 0, outbound: 0), "new device history ignored")
    expectEqual(ActivityCalculator.advance(track: &track, now: 7) {
        ["a": TransferCounters(inbound: 400, outbound: 800)]
    }, TransferRates(inbound: 100, outbound: 200), "removed device does not invalidate remaining device")
    expectEqual(ActivityCalculator.advance(track: &track, now: 10) {
        ["a": TransferCounters(inbound: 700, outbound: 1_400), "b": b]
    }, TransferRates(inbound: 100, outbound: 200), "returning device rebaselines")
    expectEqual(ActivityCalculator.advance(track: &track, now: 13) {
        ["a": TransferCounters(inbound: 1_000, outbound: 2_000),
         "b": TransferCounters(inbound: 9_000_000_600, outbound: 6_000_000_900)]
    }, TransferRates(inbound: 300, outbound: 500), "stable device rates are summed")
    expect(ActivityCalculator.advance(track: &track, now: 16) { ["c": b] } == nil, "all replacement devices need a baseline")
}

func checkNetworkCounters() throws {
    let active = UInt32(IFF_UP | IFF_RUNNING)
    let counters = try SystemMetricsSampler.networkCounters(from: [
        NetworkInterfaceCounters(id: "en0", flags: active, received: 5_000_000_000, sent: 7_000_000_000),
        NetworkInterfaceCounters(id: "en1", flags: active, received: 1_000, sent: 50),
        NetworkInterfaceCounters(id: "lo0", flags: active | UInt32(IFF_LOOPBACK), received: 9_000_000_000, sent: 9),
        NetworkInterfaceCounters(id: "en2", flags: UInt32(IFF_UP), received: 9_000_000_000, sent: 9)
    ])
    expectEqual(counters["en0"]?.inbound, 5_000_000_000, "64-bit inbound total")
    expectEqual(counters["en0"]?.outbound, 7_000_000_000, "64-bit outbound total")

    let before = try SystemMetricsSampler.networkCounters(from: [
        NetworkInterfaceCounters(id: "en0", flags: active, received: 1_000, sent: 2_000)
    ])
    let after = try SystemMetricsSampler.networkCounters(from: [
        NetworkInterfaceCounters(id: "en0", flags: active, received: 1_000, sent: 2_000),
        NetworkInterfaceCounters(id: "en1", flags: active, received: 3_000_000_000, sent: 6_000_000_000)
    ])
    let unchanged = ActivityCalculator.rates(previous: before, current: after, elapsed: 3)
    expectEqual(unchanged?.inbound, 0, "joining interface must not contribute historical traffic")

    let empty = try SystemMetricsSampler.networkCounters(from: [])
    expect(empty.isEmpty, "no active interfaces is a successful empty sample")
    var reconnectTrack = ActivityCalculator.Track()
    _ = ActivityCalculator.advance(track: &reconnectTrack, now: 1) { before }
    _ = ActivityCalculator.advance(track: &reconnectTrack, now: 4) { before }
    expect(ActivityCalculator.advance(track: &reconnectTrack, now: 7) { empty } == nil, "offline rate unavailable")
    expect(ActivityCalculator.advance(track: &reconnectTrack, now: 10) { before } == nil, "reconnected interface needs new baseline")
    expectEqual(ActivityCalculator.advance(track: &reconnectTrack, now: 13) { before }, TransferRates(inbound: 0, outbound: 0), "second reconnected sample is valid")
    expectEqual(Set(counters.keys), Set(["en0", "en1"]), "inactive and loopback interfaces excluded")

    var track = ActivityCalculator.Track()
    let baseline: TransferCounterSample = ["en0": TransferCounters(inbound: 100, outbound: 200)]
    _ = ActivityCalculator.advance(track: &track, now: 1) { baseline }
    let last = ActivityCalculator.advance(track: &track, now: 3) {
        ["en0": TransferCounters(inbound: 300, outbound: 600)]
    }
    let saved = track.previous
    var visited: [UInt32] = []
    let kept = ActivityCalculator.advance(track: &track, now: 5) {
        try SystemMetricsSampler.networkCounters(indices: [1, 7]) { index in
            visited.append(index)
            if index == 7 { throw CheckError.sample }
            return NetworkInterfaceCounters(id: "en0", flags: active, received: 500, sent: 1_000)
        }
    }
    expectEqual(visited, [1, 7], "sparse interface indices are read")
    expectEqual(kept, last, "partial read failure keeps last rate")
    expectEqual(track.previous, saved, "partial read failure preserves full baseline")
    let recovered = ActivityCalculator.advance(track: &track, now: 7) {
        ["en0": TransferCounters(inbound: 700, outbound: 1_400)]
    }
    expectEqual(recovered, TransferRates(inbound: 100, outbound: 200), "recovery uses elapsed time since last complete sample")
}

func checkSystemMetricsSampler() async throws {
    try checkNetworkCounters()
    expectEqual(
        SystemMetricsSampler.usedBytes(active: 10, wired: 20, compressor: 30, pageSize: 4096),
        245_760,
        "used memory arithmetic"
    )

    let profile = try SystemMetricsSampler.readProfile()
    expect(profile.coreCount > 0, "logical core count")
    expect(profile.totalMemory > 0, "physical memory")
    expect(!profile.hostName.isEmpty, "host name")
    expect(!profile.darwinVersion.isEmpty, "Darwin version")

    let diskCounters = try SystemMetricsSampler.readDiskCounters()
    let networkCounters = try SystemMetricsSampler.readNetworkCounters()
    expect(diskCounters.values.contains { $0.inbound > 0 || $0.outbound > 0 }, "disk counters")
    expect(networkCounters.values.contains { $0.inbound > 0 || $0.outbound > 0 }, "network counters")

    let actor = MetricsSamplingActor(profile: profile)
    let snapshot = try await actor.sample()
    expect(snapshot.cpuUsage == nil, "first live CPU sample")
    expectEqual(snapshot.coreUsage.count, profile.coreCount, "first CPU sample preserves core placeholders")
    expect(snapshot.coreUsage.allSatisfy { $0 == nil }, "first core values are unavailable")
    expect(snapshot.diskActivity == nil, "first live disk sample")
    expect(snapshot.networkActivity == nil, "first live network sample")
    expectEqual(snapshot.loadAverages.count, 3, "load average count")
    expect(snapshot.usedMemory <= snapshot.totalMemory, "used memory must not exceed total")

    try await Task.sleep(for: .milliseconds(20))
    let second = try await actor.sample()
    expect(second.diskActivity != nil, "second live disk sample")
    expect(second.networkActivity != nil, "second live network sample")
    print("LIVE: \(profile.hostName), \(profile.coreCount) cores, memory \(snapshot.usedMemory)/\(snapshot.totalMemory), Darwin \(profile.darwinVersion), \(profile.architecture)")
    print("ACTIVITY: disk R \(MetricFormatting.rate(second.diskActivity?.inbound ?? 0)) W \(MetricFormatting.rate(second.diskActivity?.outbound ?? 0)); network down \(MetricFormatting.rate(second.networkActivity?.inbound ?? 0)) up \(MetricFormatting.rate(second.networkActivity?.outbound ?? 0))")
}

enum CheckError: Error {
    case sample
}

actor MetricsFake: MetricsSampling {
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
func checkMetricsStore() async throws {
    let profile = SystemProfile(hostName: "test-mac", coreCount: 2, darwinVersion: "test", architecture: "arm64", totalMemory: 1024)
    let snapshot = MetricsSnapshot(uptime: 60, cpuUsage: 25, coreUsage: [20, 30], loadAverages: [1, 2, 3], usedMemory: 256, totalMemory: 1024)

    let idempotentFake = MetricsFake(profile: profile, results: [.success(snapshot)])
    let idempotentStore = MetricsStore(providerFactory: { idempotentFake }, sleep: { try await Task.sleep(for: .seconds(60)) })
    idempotentStore.start()
    idempotentStore.start()
    for _ in 0 ..< 50 {
        if await idempotentFake.profileCallCount > 0 { break }
        try await Task.sleep(for: .milliseconds(1))
    }
    idempotentStore.stop()
    let profileCalls = await idempotentFake.profileCallCount
    expectEqual(profileCalls, 1, "repeated start must create one refresh loop")

    let recoveryFake = MetricsFake(profile: profile, results: [.success(snapshot), .failure(CheckError.sample), .success(snapshot)])
    let recoveryStore = MetricsStore(providerFactory: { recoveryFake }, sleep: { try await Task.sleep(for: .milliseconds(1)) })
    recoveryStore.start()
    for _ in 0 ..< 100 {
        if await recoveryFake.sampleCallCount >= 3 { break }
        try await Task.sleep(for: .milliseconds(1))
    }
    recoveryStore.stop()
    expectEqual(recoveryStore.snapshot, snapshot, "failure must retain the last snapshot")
    expect(recoveryStore.errorMessage == nil, "successful retry must clear the error")
    let recoveryCalls = await recoveryFake.sampleCallCount
    expect(recoveryCalls >= 3, "sampler must recover after a transient failure")

    final class RetryGate: @unchecked Sendable {
        var allow = false
    }
    let gate = RetryGate()
    let retryFake = MetricsFake(profile: profile, results: [.success(snapshot)])
    let retryStore = MetricsStore(
        providerFactory: {
            guard gate.allow else { throw CheckError.sample }
            return retryFake
        },
        sleep: { try await Task.sleep(for: .seconds(60)) }
    )
    retryStore.start()
    for _ in 0 ..< 100 {
        if retryStore.errorMessage != nil { break }
        try await Task.sleep(for: .milliseconds(1))
    }
    expect(retryStore.errorMessage != nil, "failed profile read sets an error")
    try await Task.sleep(for: .milliseconds(1))
    gate.allow = true
    retryStore.start()
    for _ in 0 ..< 100 {
        if retryStore.snapshot == snapshot { break }
        try await Task.sleep(for: .milliseconds(1))
    }
    retryStore.stop()
    expectEqual(retryStore.snapshot, snapshot, "refresh loop must restart after it exits")
    expect(retryStore.errorMessage == nil, "restarted refresh must clear the error")

    let stopFake = MetricsFake(profile: profile, results: [.success(snapshot)])
    let stopStore = MetricsStore(providerFactory: { stopFake }, sleep: { try await Task.sleep(for: .seconds(60)) })
    stopStore.start()
    for _ in 0 ..< 100 {
        if await stopFake.sampleCallCount > 0 { break }
        try await Task.sleep(for: .milliseconds(1))
    }
    stopStore.stop()
    let stoppedCount = await stopFake.sampleCallCount
    try await Task.sleep(for: .milliseconds(10))
    let finalCount = await stopFake.sampleCallCount
    expectEqual(finalCount, stoppedCount, "stop must prevent additional samples")
}

@main
enum CheckRunner {
    static func main() async {
        setvbuf(stdout, nil, _IONBF, 0)
        setvbuf(stderr, nil, _IONBF, 0)
        let watchdog = Task.detached {
            do {
                try await Task.sleep(for: .seconds(20))
            } catch {
                return
            }
            fputs("FAIL: checks timed out\n", stderr)
            fflush(stderr)
            exit(1)
        }
        defer { watchdog.cancel() }

        checkMetricCalculations()
        pass("metric calculation checks")
        do {
            try await checkSystemMetricsSampler()
            pass("system sampler checks")
            try await checkMetricsStore()
            pass("metrics store checks")
            let lifecycle = StoreLifecycleChecks()
            await lifecycle.testCancelledSampleFailureCannotOverwriteRestartedSuccess()
            await lifecycle.testCancelledProfileCannotOverwriteRestartedProfile()
            await lifecycle.testCancelledSleepFailureCannotOverwriteRestartedSuccess()
            pass("cancelled task isolation checks")
        } catch {
            print("FAIL: async checks threw \(error)")
            fflush(stdout)
            exit(1)
        }
    }
}
