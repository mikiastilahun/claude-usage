import SwiftUI

enum Range: String, CaseIterable, Identifiable {
    case today = "Today"
    case week = "7 days"
    case month = "Month"
    case all = "All"

    var id: String { rawValue }

    func start(_ calendar: Calendar = .current) -> Date {
        let today = calendar.startOfDay(for: Date())
        switch self {
        case .today:
            return today
        case .week:
            return calendar.date(byAdding: .day, value: -6, to: today) ?? today
        case .month:
            return calendar.date(from: calendar.dateComponents([.year, .month], from: Date())) ?? today
        case .all:
            return .distantPast
        }
    }
}

struct MenuPanel: View {
    @EnvironmentObject var store: UsageStore
    @State private var range: Range = .today
    @AppStorage("showTokenDetail") private var showTokenDetail = false

    private var totals: UsageTotals { store.totals(since: range.start(), label: range.rawValue) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            planSection
            Divider()
            tokenDetail
            Divider()
            footer
        }
        .padding(14)
        .frame(width: 380)
    }

    // MARK: - Header

    private var header: some View {
        HStack {
            Image(systemName: "gauge.with.dots.needle.33percent")
                .foregroundStyle(.tint)
            Text("Plan usage limits")
                .font(.system(size: 13, weight: .semibold))
            if let tier = store.planTier {
                Text(tier)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Menu {
                Picker("Menu bar shows", selection: $store.metric) {
                    ForEach(MenuBarMetric.allCases) { m in Text(m.label).tag(m) }
                }
                Divider()
                Toggle("Launch at login", isOn: Binding(
                    get: { LoginItem.isEnabled },
                    set: { LoginItem.setEnabled($0) }
                ))
                Divider()
                Button("Quit Claude Usage") { NSApplication.shared.terminate(nil) }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
        }
    }

    // MARK: - Plan limits

    @ViewBuilder
    private var planSection: some View {
        if let plan = store.plan, !plan.limits.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                if let session = plan.session {
                    LimitBar(limit: session)
                }
                let weekly = plan.weekly
                if !weekly.isEmpty {
                    Text("Weekly limits")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                        .padding(.top, 2)
                    ForEach(weekly) { LimitBar(limit: $0) }
                }
                let other = plan.limits.filter { $0.kind != "session" && !$0.isWeekly }
                ForEach(other) { LimitBar(limit: $0) }

                if let extra = plan.extraUsage, extra.isEnabled == true, let used = extra.usedCredits {
                    Text("Usage credits: \(String(format: "%.2f", used)) \(extra.currency ?? "")")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
            }
        } else {
            planUnavailable
        }
    }

    @ViewBuilder
    private var planUnavailable: some View {
        VStack(alignment: .leading, spacing: 4) {
            switch store.planState {
            case .noCredentials:
                Label("Not signed in to Claude Code", systemImage: "person.crop.circle.badge.questionmark")
                    .font(.callout)
                Text("Run `claude` once so it stores your credentials, then refresh.")
                    .font(.caption).foregroundStyle(.secondary)
            case .unauthorized:
                Label("Session token expired", systemImage: "lock")
                    .font(.callout)
                Text("Run `claude` to refresh it — this app never writes your credentials.")
                    .font(.caption).foregroundStyle(.secondary)
            case .rateLimited:
                Label("Usage endpoint rate limited", systemImage: "clock.arrow.circlepath")
                    .font(.callout)
                Text("Backing off; showing the last known values.")
                    .font(.caption).foregroundStyle(.secondary)
            case .failed(let message):
                Label("Couldn't load plan limits", systemImage: "exclamationmark.triangle")
                    .font(.callout)
                Text(message).font(.caption).foregroundStyle(.secondary).lineLimit(2)
            case .ok:
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("Loading plan limits…").font(.callout).foregroundStyle(.secondary)
                }
            }
        }
        .padding(.vertical, 4)
    }

    // MARK: - Local token analytics

    private var tokenDetail: some View {
        DisclosureGroup(isExpanded: $showTokenDetail) {
            VStack(alignment: .leading, spacing: 12) {
                activeBlockCard
                rangePicker
                totalsSummary
                if range != .all { sparkline }
                breakdown(title: "Models", rows: store.breakdownByModel(since: range.start()), limit: 4)
                let projects = store.breakdownByProject(since: range.start())
                if projects.count > 1 {
                    breakdown(title: "Projects", rows: projects, limit: 4)
                }
            }
            .padding(.top, 8)
        } label: {
            HStack {
                Text("Tokens & cost")
                    .font(.system(size: 12, weight: .medium))
                Spacer()
                Text("\(Format.cost(store.today.cost)) today")
                    .font(.system(size: 11).monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private var activeBlockCard: some View {
        if let block = store.activeBlock {
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline) {
                    Text(Format.cost(block.totals.cost))
                        .font(.system(size: 20, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                    Text("this 5-hour block")
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Text(Format.duration(block.timeRemaining) + " left")
                        .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                }
                ProgressView(value: block.elapsedFraction).tint(.accentColor)
                HStack {
                    Text(Format.clockRange(block.start, block.end))
                    Spacer()
                    Text("\(Format.cost(block.burnRate))/hr · ~\(Format.cost(block.projectedCost)) projected")
                }
                .font(.caption2).foregroundStyle(.secondary)
            }
            .padding(9)
            .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
        }
    }

    private var rangePicker: some View {
        Picker("", selection: $range) {
            ForEach(Range.allCases) { r in Text(r.rawValue).tag(r) }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
    }

    private var totalsSummary: some View {
        VStack(spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(Format.cost(totals.cost))
                    .font(.system(size: 18, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                Text("API-equivalent")
                    .font(.caption2).foregroundStyle(.tertiary)
                Spacer()
                Text("\(totals.messages) responses")
                    .font(.caption).foregroundStyle(.secondary)
            }
            HStack(spacing: 0) {
                tokenStat("Input", totals.inputTokens)
                tokenStat("Output", totals.outputTokens)
                tokenStat("Cache write", totals.cacheWrite)
                tokenStat("Cache read", totals.cacheRead)
            }
        }
    }

    private func tokenStat(_ label: String, _ value: Int) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(Format.tokens(value))
                .font(.system(size: 12, weight: .medium)).monospacedDigit()
            Text(label).font(.system(size: 9)).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var sparkline: some View {
        let days = range == .today ? 14 : (range == .week ? 7 : 30)
        let data = store.dailyCosts(days: days)
        let peak = max(data.map(\.cost).max() ?? 0, 0.0001)
        return VStack(alignment: .leading, spacing: 4) {
            Text("Last \(days) days").font(.caption).foregroundStyle(.secondary)
            HStack(alignment: .bottom, spacing: 2) {
                ForEach(data, id: \.date) { point in
                    RoundedRectangle(cornerRadius: 1.5)
                        .fill(point.cost > 0 ? Color.accentColor.opacity(0.85) : Color.secondary.opacity(0.2))
                        .frame(height: max(2, 30 * point.cost / peak))
                        .help("\(Format.weekday(point.date)) · \(Format.cost(point.cost))")
                }
            }
            .frame(height: 30)
        }
    }

    private func breakdown(title: String, rows: [UsageTotals], limit: Int) -> some View {
        let shown = Array(rows.prefix(limit))
        let peak = max(shown.first?.cost ?? 0, 0.0001)
        return VStack(alignment: .leading, spacing: 5) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            if shown.isEmpty {
                Text("No usage in this range").font(.caption2).foregroundStyle(.tertiary)
            }
            ForEach(shown) { row in
                HStack(spacing: 8) {
                    Text(row.label)
                        .font(.system(size: 11)).lineLimit(1)
                        .frame(width: 110, alignment: .leading)
                    GeometryReader { geo in
                        RoundedRectangle(cornerRadius: 2)
                            .fill(Color.accentColor.opacity(0.7))
                            .frame(width: max(2, geo.size.width * row.cost / peak))
                    }
                    .frame(height: 6)
                    Text(Format.cost(row.cost))
                        .font(.system(size: 11).monospacedDigit())
                        .foregroundStyle(.secondary)
                        .frame(width: 54, alignment: .trailing)
                }
            }
        }
    }

    // MARK: - Footer

    private var footer: some View {
        HStack(spacing: 6) {
            if let fetched = store.plan?.fetchedAt {
                Text("Last updated \(Format.relative(fetched))")
            } else {
                Text("Reading usage…")
            }
            Button {
                Task { await store.refreshPlan(force: true); await store.refresh() }
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.borderless)
            .help("Refresh now")
            Spacer()
            Text("\(store.entries.count) responses tracked")
        }
        .font(.caption2)
        .foregroundStyle(.tertiary)
    }
}
