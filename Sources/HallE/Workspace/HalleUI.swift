import SwiftUI

enum HalleUI {
    static let cornerRadius: CGFloat = 10
    static let sectionSpacing: CGFloat = 18
}

enum HalleStatusTone {
    case neutral, info, success, warning, error, recording
    var color: Color {
        switch self {
        case .neutral: .secondary
        case .info: .accentColor
        case .success: .green
        case .warning: .orange
        case .error, .recording: .red
        }
    }
}

struct HalleStatusBadge: View {
    let text: String
    var tone: HalleStatusTone = .neutral
    var body: some View {
        Text(text).font(.caption2.weight(.medium))
            .foregroundStyle(tone.color)
            .padding(.horizontal, 7).padding(.vertical, 3)
            .background(tone.color.opacity(0.12), in: Capsule())
            .accessibilityLabel(text)
    }
}

struct HalleCard<Content: View>: View {
    @ViewBuilder let content: Content
    var body: some View {
        content
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: HalleUI.cornerRadius))
            .overlay(RoundedRectangle(cornerRadius: HalleUI.cornerRadius).stroke(.separator.opacity(0.55)))
    }
}

struct HalleEmptyState: View {
    let symbol: String
    let title: String
    let detail: String
    var body: some View {
        ContentUnavailableView { Label(title, systemImage: symbol) } description: { Text(detail) }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct MetricPill: View {
    let value: String
    let label: String
    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(value).font(.headline.monospacedDigit())
            Text(label).font(.caption).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 11).padding(.vertical, 8)
        .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 8))
    }
}
