import Foundation

protocol MetricsSampling: Sendable {
    func profile() async -> SystemProfile
    func sample() async throws -> MetricsSnapshot
}

actor MetricsSamplingActor: MetricsSampling {
    let systemProfile: SystemProfile
    private var previousTicks: [CPUTicks]?
    private var diskTrack = ActivityCalculator.Track()
    private var networkTrack = ActivityCalculator.Track()

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
        let diskActivity = ActivityCalculator.advance(track: &diskTrack, now: now) {
            try SystemMetricsSampler.readDiskCounters()
        }
        let networkActivity = ActivityCalculator.advance(track: &networkTrack, now: now) {
            try SystemMetricsSampler.readNetworkCounters()
        }

        return MetricsSnapshot(
            uptime: now,
            cpuUsage: cpu?.total,
            coreUsage: cpu?.cores ?? Array(repeating: nil, count: currentTicks.count),
            loadAverages: try SystemMetricsSampler.readLoadAverages(),
            usedMemory: try SystemMetricsSampler.readUsedMemory(),
            totalMemory: systemProfile.totalMemory,
            diskActivity: diskActivity,
            networkActivity: networkActivity
        )
    }
}
