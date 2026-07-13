import Foundation

public struct UsageWindow {
    public var utilization: Double
    public var resetsAt: Date?

    public init(utilization: Double, resetsAt: Date?) {
        self.utilization = utilization
        self.resetsAt = resetsAt
    }
}

public struct ExtraWindow {
    public var label: String
    public var window: UsageWindow

    public init(label: String, window: UsageWindow) {
        self.label = label
        self.window = window
    }
}

public struct ParsedUsage {
    public var fiveHour: UsageWindow
    public var sevenDay: UsageWindow
    public var extra: [ExtraWindow]
    public var cookieSource: String

    public static func parse(_ json: [String: Any], source: String) -> ParsedUsage {
        func parseDate(_ str: String) -> Date? {
            let f = ISO8601DateFormatter()
            f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let d = f.date(from: str) { return d }
            f.formatOptions = [.withInternetDateTime]
            return f.date(from: str)
        }

        func parseWindow(_ dict: [String: Any]) -> UsageWindow {
            let pct  = dict["utilization"] as? Double ?? 0
            let date = (dict["resets_at"] as? String).flatMap { parseDate($0) }
            return UsageWindow(utilization: pct, resetsAt: date)
        }

        func window(_ key: String) -> UsageWindow {
            parseWindow(json[key] as? [String: Any] ?? [:])
        }

        let knownKeys: Set<String> = ["five_hour", "seven_day", "amber_ladder"]
        var extra: [ExtraWindow] = []
        for (key, value) in json {
            guard !knownKeys.contains(key),
                  let dict = value as? [String: Any],
                  dict["utilization"] != nil else { continue }
            let label = key
                .split(separator: "_")
                .map { $0.prefix(1).uppercased() + $0.dropFirst() }
                .joined(separator: " ")
            extra.append(ExtraWindow(label: label, window: parseWindow(dict)))
        }
        extra.sort {
            switch ($0.window.resetsAt, $1.window.resetsAt) {
            case (.some, .none): return true
            case (.none, .some): return false
            default:             return $0.label < $1.label
            }
        }

        return ParsedUsage(
            fiveHour: window("five_hour"),
            sevenDay: window("seven_day"),
            extra: extra,
            cookieSource: source
        )
    }
}

public func formatResetCountdown(seconds: Int) -> String {
    let d = seconds / 86400
    let h = (seconds % 86400) / 3600
    let m = (seconds % 3600) / 60
    if d > 0 {
        return "\(d)d \(h)h \(m)m"
    } else if h > 0 {
        return "\(h)h \(m)m"
    } else {
        return "\(m)m"
    }
}
