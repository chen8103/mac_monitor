import Foundation

struct CPUTicks: Equatable, Sendable {
    let user: UInt64
    let system: UInt64
    let idle: UInt64
    let nice: UInt64
}

struct SystemProfile: Equatable, Sendable {
    let hostName: String
    let coreCount: Int
    let darwinVersion: String
    let architecture: String
    let totalMemory: UInt64
}

struct TransferCounters: Equatable, Sendable {
    let inbound: UInt64
    let outbound: UInt64
}

struct TransferRates: Equatable, Sendable {
    let inbound: Double
    let outbound: Double
}

struct MetricsSnapshot: Equatable, Sendable {
    let uptime: TimeInterval
    let cpuUsage: Double?
    let coreUsage: [Double]
    let loadAverages: [Double]
    let usedMemory: UInt64
    let totalMemory: UInt64
    let diskActivity: TransferRates?
    let networkActivity: TransferRates?

    init(
        uptime: TimeInterval,
        cpuUsage: Double?,
        coreUsage: [Double],
        loadAverages: [Double],
        usedMemory: UInt64,
        totalMemory: UInt64,
        diskActivity: TransferRates? = nil,
        networkActivity: TransferRates? = nil
    ) {
        self.uptime = uptime
        self.cpuUsage = cpuUsage
        self.coreUsage = coreUsage
        self.loadAverages = loadAverages
        self.usedMemory = usedMemory
        self.totalMemory = totalMemory
        self.diskActivity = diskActivity
        self.networkActivity = networkActivity
    }
}

enum LoadLevel: Equatable, Sendable {
    case normal
    case warning
    case critical

    static func cpu(_ value: Double) -> LoadLevel {
        level(value, warning: 70)
    }

    static func memory(_ value: Double) -> LoadLevel {
        level(value, warning: 80)
    }

    private static func level(_ value: Double, warning: Double) -> LoadLevel {
        if value >= 90 { return .critical }
        if value >= warning { return .warning }
        return .normal
    }
}
