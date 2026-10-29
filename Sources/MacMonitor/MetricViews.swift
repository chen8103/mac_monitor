import SwiftUI

extension Color {
    init(hex: UInt) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255,
            opacity: 1
        )
    }

    static let panelBackground = Color(hex: 0xF7F8FA)
    static let primaryText = Color(hex: 0x20242B)
    static let secondaryText = Color(hex: 0x6D7480)
    static let barTrack = Color(hex: 0xE5E9EF)
    static let cpuBlue = Color(hex: 0x4385F5)
    static let memoryTeal = Color(hex: 0x20B8A6)
    static let warningOrange = Color(hex: 0xF5A623)
    static let criticalCoral = Color(hex: 0xEF6262)
}

extension LoadLevel {
    var cpuColor: Color {
        switch self {
        case .normal: .cpuBlue
        case .warning: .warningOrange
        case .critical: .criticalCoral
        }
    }

    var memoryColor: Color {
        switch self {
        case .normal: .memoryTeal
        case .warning: .warningOrange
        case .critical: .criticalCoral
        }
    }
}

struct MetricBar: View {
    let value: Double
    let color: Color
    var height: CGFloat = 10

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.barTrack)
                Capsule()
                    .fill(color)
                    .frame(width: geometry.size.width * min(max(value, 0), 1))
            }
        }
        .frame(height: height)
        .accessibilityValue("\(Int(min(max(value, 0), 1) * 100))%")
    }
}

struct CoreUsageGrid: View {
    let values: [Double]
    private let columns = [GridItem(.adaptive(minimum: 68), spacing: 8)]

    var body: some View {
        LazyVGrid(columns: columns, alignment: .leading, spacing: 8) {
            ForEach(Array(values.enumerated()), id: \.offset) { index, value in
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("C\(index)")
                        Spacer()
                        Text(MetricFormatting.percent(value))
                    }
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(Color.secondaryText)
                    MetricBar(value: value / 100, color: LoadLevel.cpu(value).cpuColor, height: 6)
                }
            }
        }
    }
}
