import Foundation

enum Granularity: String, CaseIterable, Identifiable {
    case hour = "小时"
    case day = "天"
    case week = "周"
    case month = "月"
    case total = "总计"

    var id: String { rawValue }
}

enum UsageAggregator {
    private static let calendar = Calendar.current

    private static let dayLabelFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "M月d日 EEE"
        f.locale = Locale(identifier: "zh_CN")
        return f
    }()

    private static let hourLabelFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:00"
        return f
    }()

    private static let monthLabelFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy年M月"
        f.locale = Locale(identifier: "zh_CN")
        return f
    }()

    /// Buckets events by the requested granularity, newest first. `.total` collapses
    /// everything into a single bucket.
    static func buckets(for events: [UsageEvent], granularity: Granularity) -> [UsageBucket] {
        guard !events.isEmpty else { return [] }

        switch granularity {
        case .hour:
            return bucket(
                events,
                startFor: { calendar.dateInterval(of: .hour, for: $0)?.start ?? $0 },
                idFor: { "h-\($0.timeIntervalSinceReferenceDate)" },
                labelFor: { hourLabelFormatter.string(from: $0) }
            )
        case .day:
            return bucket(
                events,
                startFor: { calendar.startOfDay(for: $0) },
                idFor: { "d-\($0.timeIntervalSinceReferenceDate)" },
                labelFor: { dayLabelFormatter.string(from: $0) }
            )
        case .week:
            return bucket(
                events,
                startFor: { calendar.dateInterval(of: .weekOfYear, for: $0)?.start ?? $0 },
                idFor: { "w-\($0.timeIntervalSinceReferenceDate)" },
                labelFor: { weekLabel($0) }
            )
        case .month:
            return bucket(
                events,
                startFor: { calendar.dateInterval(of: .month, for: $0)?.start ?? $0 },
                idFor: { "m-\($0.timeIntervalSinceReferenceDate)" },
                labelFor: { monthLabelFormatter.string(from: $0) }
            )
        case .total:
            var bucket = UsageBucket(id: "total", label: "全部", startDate: .distantPast)
            for event in events {
                bucket.totalsByTool[event.tool, default: ToolTotals()].add(event)
            }
            return [bucket]
        }
    }

    private static func bucket(
        _ events: [UsageEvent],
        startFor: (Date) -> Date,
        idFor: (Date) -> String,
        labelFor: (Date) -> String
    ) -> [UsageBucket] {
        var totalsByStart: [Date: [Tool: ToolTotals]] = [:]
        for event in events {
            let start = startFor(event.date)
            totalsByStart[start, default: [:]][event.tool, default: ToolTotals()].add(event)
        }
        return totalsByStart.map { start, totals in
            UsageBucket(
                id: idFor(start),
                label: labelFor(start),
                startDate: start,
                totalsByTool: totals
            )
        }.sorted { $0.startDate > $1.startDate }
    }

    private static func weekLabel(_ start: Date) -> String {
        guard let end = calendar.date(byAdding: .day, value: 6, to: start) else {
            return dayLabelFormatter.string(from: start)
        }
        return "\(dayLabelFormatter.string(from: start)) – \(dayLabelFormatter.string(from: end))"
    }
}
