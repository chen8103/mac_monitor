import Foundation

func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    if !condition() {
        print("FAIL: \(message)")
        exit(1)
    }
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

    let emptyBars = ActivityCalculator.barFractions(for: nil)
    expectEqual(emptyBars.inbound, 0, "empty inbound bar")
    expectEqual(emptyBars.outbound, 0, "empty outbound bar")
    let lowBars = ActivityCalculator.barFractions(for: TransferRates(inbound: 524_288, outbound: 262_144))
    expect(abs(lowBars.inbound - 0.5) < 0.001, "minimum-scale inbound bar")
    expect(abs(lowBars.outbound - 0.25) < 0.001, "minimum-scale outbound bar")
    let highBars = ActivityCalculator.barFractions(for: TransferRates(inbound: 8_388_608, outbound: 2_097_152))
    expectEqual(highBars.inbound, 1, "peak inbound bar")
    expect(abs(highBars.outbound - 0.25) < 0.001, "relative outbound bar")

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
    expect(abs((usage?.cores.first ?? -1) - 25) < 0.001, "per-core CPU delta")

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

func checkSystemMetricsSampler() async throws {
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
    expect(diskCounters.inbound > 0 || diskCounters.outbound > 0, "disk counters")
    expect(networkCounters.inbound > 0 || networkCounters.outbound > 0, "network counters")

    let actor = MetricsSamplingActor(profile: profile)
    let snapshot = try await actor.sample()
    expect(snapshot.cpuUsage == nil, "first live CPU sample")
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
    for _ in 0 ..< 20 {
        if await idempotentFake.profileCallCount > 0 { break }
        await Task.yield()
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

    let stopFake = MetricsFake(profile: profile, results: [.success(snapshot)])
    let stopStore = MetricsStore(providerFactory: { stopFake }, sleep: { try await Task.sleep(for: .seconds(60)) })
    stopStore.start()
    for _ in 0 ..< 100 {
        if await stopFake.sampleCallCount > 0 { break }
        await Task.yield()
    }
    stopStore.stop()
    let stoppedCount = await stopFake.sampleCallCount
    try await Task.sleep(for: .milliseconds(10))
    let finalCount = await stopFake.sampleCallCount
    expectEqual(finalCount, stoppedCount, "stop must prevent additional samples")
}

checkMetricCalculations()
print("PASS: metric calculation checks")

Task {
    do {
        try await checkSystemMetricsSampler()
        print("PASS: system sampler checks")
        try await checkMetricsStore()
        print("PASS: metrics store checks")
        exit(0)
    } catch {
        print("FAIL: async checks threw \(error)")
        exit(1)
    }
}

dispatchMain()
