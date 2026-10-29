import Foundation

enum CPUCalculator {
    static func usage(previous: [CPUTicks]?, current: [CPUTicks]) -> (total: Double, cores: [Double?])? {
        guard let previous, !previous.isEmpty, previous.count == current.count else {
            return nil
        }

        var totalBusy = 0.0
        var totalElapsed = 0.0
        var cores: [Double?] = []
        cores.reserveCapacity(current.count)

        for (old, new) in zip(previous, current) {
            guard new.user >= old.user,
                  new.system >= old.system,
                  new.idle >= old.idle,
                  new.nice >= old.nice else {
                return nil
            }

            let busy = Double(new.user - old.user + new.system - old.system + new.nice - old.nice)
            let elapsed = busy + Double(new.idle - old.idle)
            totalBusy += busy
            totalElapsed += elapsed
            cores.append(elapsed > 0 ? clamp(100 * busy / elapsed) : nil)
        }

        guard totalElapsed > 0 else { return nil }
        return (clamp(100 * totalBusy / totalElapsed), cores)
    }

    private static func clamp(_ value: Double) -> Double {
        min(max(value, 0), 100)
    }
}

enum ActivityCalculator {
    struct Sample: Equatable, Sendable {
        var counters: TransferCounterSample
        var time: TimeInterval
    }

    struct Track: Equatable, Sendable {
        var previous: Sample?
        var lastRate: TransferRates?
    }

    static func rates(
        previous: TransferCounters?,
        current: TransferCounters,
        elapsed: TimeInterval
    ) -> TransferRates? {
        guard let previous,
              elapsed > 0,
              current.inbound >= previous.inbound,
              current.outbound >= previous.outbound else {
            return nil
        }

        return TransferRates(
            inbound: Double(current.inbound - previous.inbound) / elapsed,
            outbound: Double(current.outbound - previous.outbound) / elapsed
        )
    }

    static func rates(
        previous: TransferCounterSample?,
        current: TransferCounterSample,
        elapsed: TimeInterval
    ) -> TransferRates? {
        guard let previous, elapsed.isFinite, elapsed > 0 else { return nil }
        var inbound = 0.0
        var outbound = 0.0
        var matched = false
        for (id, counters) in current {
            guard let rate = rates(previous: previous[id], current: counters, elapsed: elapsed) else {
                continue
            }
            inbound += rate.inbound
            outbound += rate.outbound
            matched = true
        }
        return matched ? TransferRates(inbound: inbound, outbound: outbound) : nil
    }

    /// A failed counter read keeps the last rate. An invalid delta stays unavailable
    /// and still moves the baseline forward.
    static func advance(
        track: inout Track,
        now: TimeInterval,
        read: () throws -> TransferCounterSample
    ) -> TransferRates? {
        let counters: TransferCounterSample
        do {
            counters = try read()
        } catch {
            return track.lastRate
        }

        let rate = rates(
            previous: track.previous?.counters,
            current: counters,
            elapsed: now - (track.previous?.time ?? now)
        )
        track.previous = Sample(counters: counters, time: now)
        if let rate {
            track.lastRate = rate
        }
        return rate
    }

    static func barFractions(
        for rates: TransferRates?,
        minimumScale: Double = 1_048_576
    ) -> (inbound: Double, outbound: Double)? {
        guard let rates else { return nil }
        let scale = max(minimumScale, rates.inbound, rates.outbound)
        return (
            min(max(rates.inbound / scale, 0), 1),
            min(max(rates.outbound / scale, 0), 1)
        )
    }
}

enum MetricFormatting {
    static func percent(_ value: Double) -> String {
        String(format: "%.1f%%", min(max(value, 0), 100))
    }

    static func gibibytes(_ bytes: UInt64) -> String {
        String(format: "%.1f", Double(bytes) / 1_073_741_824)
    }

    static func rate(_ bytesPerSecond: Double) -> String {
        let units = ["B/s", "KB/s", "MB/s", "GB/s"]
        var value = max(0, bytesPerSecond)
        var unit = 0
        while value >= 1_024, unit < units.count - 1 {
            value /= 1_024
            unit += 1
        }
        return String(format: "%.1f %@", value, units[unit])
    }

    static func uptime(_ interval: TimeInterval) -> String {
        let minutes = max(0, Int(interval) / 60)
        let days = minutes / 1_440
        let hours = (minutes % 1_440) / 60
        let remainingMinutes = minutes % 60

        if days > 0 {
            return "\(days)d \(hours)h \(remainingMinutes)m"
        }
        if hours > 0 {
            return "\(hours)h \(remainingMinutes)m"
        }
        return "\(remainingMinutes)m"
    }
}
