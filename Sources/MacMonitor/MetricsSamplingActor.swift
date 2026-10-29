import Foundation

protocol MetricsSampling: Sendable {
    func profile() async -> SystemProfile
    func sample() async throws -> MetricsSnapshot
}

actor MetricsSamplingActor: MetricsSampling {
    let systemProfile: SystemProfile
    private var previousTicks: [CPUTicks]?
    private var previousDisk: (counters: TransferCounters, time: TimeInterval)?
    private var previousNetwork: (counters: TransferCounters, time: TimeInterval)?

    init(profile: SystemProfile) {
        systemProfile = profile
    }

    func profile() async -> SystemProfile {
        systemProfile
    }

    func sample() async throws -> MetricsSnapshot {
        let currentTicks = try SystemMetricsSampler.readCPUTicks()
        let cpu = CPUCalculator.usage(previous: previousTicks, current: currentTicks)
        previousTicks = currentTicks

        let now = ProcessInfo.processInfo.systemUptime
        var diskActivity: TransferRates?
        if let counters = try? SystemMetricsSampler.readDiskCounters() {
            diskActivity = ActivityCalculator.rates(
                previous: previousDisk?.counters,
                current: counters,
                elapsed: now - (previousDisk?.time ?? now)
            )
            previousDisk = (counters, now)
        }

        var networkActivity: TransferRates?
        if let counters = try? SystemMetricsSampler.readNetworkCounters() {
            networkActivity = ActivityCalculator.rates(
                previous: previousNetwork?.counters,
                current: counters,
                elapsed: now - (previousNetwork?.time ?? now)
            )
            previousNetwork = (counters, now)
        }

        return MetricsSnapshot(
            uptime: now,
            cpuUsage: cpu?.total,
            coreUsage: cpu?.cores ?? [],
            loadAverages: try SystemMetricsSampler.readLoadAverages(),
            usedMemory: try SystemMetricsSampler.readUsedMemory(),
            totalMemory: systemProfile.totalMemory,
            diskActivity: diskActivity,
            networkActivity: networkActivity
        )
    }
}
