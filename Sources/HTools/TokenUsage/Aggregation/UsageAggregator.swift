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
    /// Buckets events by the requested granularity, newest first. `.total` collapses
    /// everything into a single bucket.
    static func buckets(for events: [UsageEvent], granularity: Granularity, timeZone: TimeZone = .current) -> [UsageBucket] {
        var calendar = Calendar.current
        calendar.timeZone = timeZone
        func formatter(_ format: String) -> DateFormatter {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "zh_CN")
            formatter.calendar = calendar
            formatter.timeZone = timeZone
            formatter.dateFormat = format
            return formatter
        }
        let dayLabelFormatter = formatter("M月d日 EEE")
        let hourLabelFormatter = formatter("HH:mm")
        let monthLabelFormatter = formatter("yyyy年M月")
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
                labelFor: { start in
                    guard let end = calendar.date(byAdding: .day, value: 6, to: start) else {
                        return dayLabelFormatter.string(from: start)
                    }
                    return "\(dayLabelFormatter.string(from: start)) – \(dayLabelFormatter.string(from: end))"
                }
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
}
