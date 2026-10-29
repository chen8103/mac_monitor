import AppKit
import SwiftUI

struct MonitorView: View {
    @ObservedObject var store: MetricsStore

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                cpuSection
                memorySection
                activitySection(
                    title: "DISK",
                    rates: store.snapshot?.diskActivity,
                    inboundLabel: "R",
                    outboundLabel: "W",
                    inboundColor: .cpuBlue,
                    outboundColor: .warningOrange
                )
                activitySection(
                    title: "NETWORK",
                    rates: store.snapshot?.networkActivity,
                    inboundLabel: "↓",
                    outboundLabel: "↑",
                    inboundColor: .memoryTeal,
                    outboundColor: .purple
                )
                Divider()
                    .overlay(Color.barTrack)
                footer
            }
            .padding(20)
        }
        .frame(width: 420, height: 500)
        .background(Color.panelBackground)
        .task {
            store.start()
        }
        .onDisappear {
            store.stop()
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Text(store.profile?.hostName ?? "Mac")
                .font(.system(size: 20, weight: .semibold, design: .rounded))
                .foregroundStyle(Color.primaryText)
                .lineLimit(1)
                .minimumScaleFactor(0.65)
                .truncationMode(.middle)
            Spacer(minLength: 8)
            Text("up \(store.snapshot.map { MetricFormatting.uptime($0.uptime) } ?? "—")")
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(Color.secondaryText)
        }
    }

    private var cpuSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text("CPU")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Color.secondaryText)
                Spacer()
                Text(store.snapshot?.cpuUsage.map(MetricFormatting.percent) ?? "—")
                    .font(.system(size: 22, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(Color.primaryText)
            }

            let usage = store.snapshot?.cpuUsage
            MetricBar(value: (usage ?? 0) / 100, color: usage.map { LoadLevel.cpu($0).cpuColor } ?? .cpuBlue)

            Text(cpuDetails)
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(Color.secondaryText)

            CoreUsageGrid(values: store.snapshot?.coreUsage ?? [])
        }
    }

    private var cpuDetails: String {
        let cores = store.profile.map { "\($0.coreCount) cores" } ?? "— cores"
        guard let loads = store.snapshot?.loadAverages, loads.count == 3 else {
            return "\(cores) · load —"
        }
        let values = loads.map { String(format: "%.1f", $0) }.joined(separator: " ")
        return "\(cores) · load \(values)"
    }

    private var memorySection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text("MEMORY")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Color.secondaryText)
                Spacer()
                Text(memoryText)
                    .font(.system(size: 18, weight: .medium, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(Color.primaryText)
            }

            let fraction = memoryFraction
            MetricBar(value: fraction, color: LoadLevel.memory(fraction * 100).memoryColor)
        }
    }

    private var memoryText: String {
        let total = store.snapshot?.totalMemory ?? store.profile?.totalMemory
        let totalText = total.map(MetricFormatting.gibibytes) ?? "—"
        guard let snapshot = store.snapshot else {
            return "— / \(totalText) GiB"
        }
        return "\(MetricFormatting.gibibytes(snapshot.usedMemory)) / \(totalText) GiB"
    }

    private var memoryFraction: Double {
        guard let snapshot = store.snapshot, snapshot.totalMemory > 0 else { return 0 }
        return min(max(Double(snapshot.usedMemory) / Double(snapshot.totalMemory), 0), 1)
    }

    private func activitySection(
        title: String,
        rates: TransferRates?,
        inboundLabel: String,
        outboundLabel: String,
        inboundColor: Color,
        outboundColor: Color
    ) -> some View {
        let fractions = ActivityCalculator.barFractions(for: rates)
        return VStack(spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text(title)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Color.secondaryText)
                Spacer()
                if let rates {
                    HStack(spacing: 14) {
                        activityRate(label: inboundLabel, value: rates.inbound)
                        activityRate(label: outboundLabel, value: rates.outbound)
                    }
                } else {
                    Text("—")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(Color.primaryText)
                }
            }
            HStack(spacing: 8) {
                MetricBar(value: fractions.inbound, color: inboundColor, height: 6)
                MetricBar(value: fractions.outbound, color: outboundColor, height: 6)
            }
        }
    }

    private func activityRate(label: String, value: Double) -> some View {
        HStack(spacing: 4) {
            Text(label)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Color.secondaryText)
            Text(MetricFormatting.rate(value))
                .font(.system(size: 12, weight: .medium, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(Color.primaryText)
        }
    }

    private var footer: some View {
        HStack(spacing: 6) {
            if let profile = store.profile {
                Text("Darwin \(profile.darwinVersion) · \(profile.architecture)")
            } else {
                Text("Darwin — · —")
            }
            Text("·")
            Text(store.errorMessage == nil ? "3s 刷新" : "刷新失败，保留上次数据")
            Spacer()
            Button {
                NSApplication.shared.terminate(nil)
            } label: {
                Label("退出", systemImage: "power")
            }
            .buttonStyle(.borderless)
            .foregroundStyle(Color.secondaryText)
        }
        .font(.system(size: 11, design: .monospaced))
        .foregroundStyle(store.errorMessage == nil ? Color.secondaryText : Color.criticalCoral)
        .lineLimit(1)
        .minimumScaleFactor(0.8)
    }
}
