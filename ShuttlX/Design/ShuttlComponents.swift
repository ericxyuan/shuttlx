import SwiftUI
import ShuttlXCore

extension Color {
    static let shuttlAccent = Color("AccentColor")
    static let shuttlSurface = Color(uiColor: .secondarySystemGroupedBackground)
    static let shuttlBackground = Color(uiColor: .systemGroupedBackground)
}

struct ShuttlCard<Content: View>: View {
    let title: String
    var subtitle: String? = nil
    @ViewBuilder var content: Content
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            if !title.isEmpty {
                VStack(alignment: .leading, spacing: 5) {
                    Text(title).font(.headline).accessibilityAddTraits(.isHeader)
                    if let subtitle { Text(subtitle).font(.subheadline).foregroundStyle(.secondary) }
                }
            }
            content
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.shuttlSurface, in: RoundedRectangle(cornerRadius: 24))
        .overlay {
            if contrast == .increased {
                RoundedRectangle(cornerRadius: 24).stroke(.primary.opacity(0.35), lineWidth: 1)
            }
        }
        .shadow(color: .black.opacity(0.025), radius: 12, x: 0, y: 3)
    }
}

struct ShuttlStatRow: View {
    let label: String
    let value: String
    var unit: String = ""

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(label).foregroundStyle(.primary)
            Spacer(minLength: 12)
            Text(value).fontWeight(.semibold).monospacedDigit()
            if !unit.isEmpty { Text(unit).font(.caption).foregroundStyle(.secondary) }
            }
            VStack(alignment: .leading, spacing: 6) {
                Text(label).foregroundStyle(.primary)
                Text(unit.isEmpty ? value : "\(value) \(unit)").fontWeight(.semibold).monospacedDigit()
            }
        }
        .font(.subheadline)
        .padding(.vertical, 8)
        .accessibilityElement(children: .combine)
    }
}

struct ShuttlHeroMetric: View {
    let value: String
    let label: String
    var unit: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(value).font(.system(.largeTitle, design: .rounded, weight: .semibold)).monospacedDigit()
                if !unit.isEmpty { Text(unit).font(.subheadline).foregroundStyle(.secondary) }
            }
            Text(label).font(.subheadline).foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
    }
}

struct ShuttlSectionHeader: View {
    let title: String
    var subtitle: String? = nil
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.title2.bold()).accessibilityAddTraits(.isHeader)
            if let subtitle { Text(subtitle).font(.subheadline).foregroundStyle(.secondary) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, 8)
    }
}

struct ShuttlEmptyState: View {
    let title: String
    let message: String
    let systemImage: String

    var body: some View {
        ContentUnavailableView {
            Label(title, systemImage: systemImage)
        } description: {
            Text(message)
        }
        .padding(.vertical, 24)
    }
}

struct ShuttlPeriodPicker: View {
    @Binding var selection: AnalyticsPeriod
    var body: some View {
        Menu {
            Picker("Time period", selection: $selection) {
                ForEach(AnalyticsPeriod.allCases, id: \.self) { period in
                    Text(period.displayName).tag(period)
                }
            }
        } label: {
            HStack(spacing: 7) {
                Image(systemName: "calendar")
                Text(selection.displayName).fontWeight(.medium)
                Image(systemName: "chevron.down").font(.caption2.bold())
            }
            .font(.subheadline)
            .padding(.horizontal, 16).padding(.vertical, 12)
            .shuttlGlass()
        }
        .accessibilityLabel("Time period")
        .accessibilityValue(selection.displayName)
    }
}

extension View {
    func shuttlGlass() -> some View { modifier(ShuttlGlassModifier()) }
}

private struct ShuttlGlassModifier: ViewModifier {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    func body(content: Content) -> some View {
        if reduceTransparency {
            content.background(Color.shuttlSurface, in: Capsule())
        } else if #available(iOS 26.0, *) {
            content.glassEffect(.regular.interactive(), in: .capsule)
        } else { content.background(.regularMaterial, in: Capsule()) }
    }
}

enum ShuttlFormat {
    static func number(_ value: Double?, digits: Int = 0) -> String {
        guard let value, value.isFinite else { return "—" }
        return value.formatted(.number.precision(.fractionLength(digits)))
    }
    static func duration(_ seconds: Double) -> String {
        let total = Int(max(0, seconds))
        if total >= 3600 { return String(format: "%d:%02d:%02d", total / 3600, total / 60 % 60, total % 60) }
        return String(format: "%d:%02d", total / 60, total % 60)
    }
    static func percent(_ count: Int, of total: Int) -> String {
        total > 0 ? (Double(count) / Double(total)).formatted(.percent.precision(.fractionLength(0))) : "—"
    }
    static let swingExplanation = "Swing Speed is estimated from wrist motion and is designed primarily to compare your own swings over time. It is not shuttle speed. A calibrated effective lever arm is required before speed is shown."
}
