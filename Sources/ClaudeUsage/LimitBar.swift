import SwiftUI

/// One plan limit rendered as a labelled progress bar, mirroring Claude's usage panel.
struct LimitBar: View {
    let limit: PlanUsage.Limit

    private var tint: Color {
        switch limit.severity {
        case "warning": return .orange
        case "critical", "exceeded", "blocked": return .red
        default: return .accentColor
        }
    }

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            VStack(alignment: .leading, spacing: 1) {
                Text(limit.label)
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
                if let resets = limit.resetsAt {
                    Text(Format.resetsIn(resets))
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .frame(width: 122, alignment: .leading)

            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.secondary.opacity(0.18))
                    Capsule()
                        .fill(tint)
                        .frame(width: max(3, geo.size.width * min(limit.percent, 100) / 100))
                }
            }
            .frame(height: 6)

            Text("\(Format.percent(limit.percent)) used")
                .font(.system(size: 11).monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 66, alignment: .trailing)
        }
    }
}
