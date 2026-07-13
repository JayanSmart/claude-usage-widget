import Foundation
import ClaudeUsageCore

var passed = 0
var failed = 0

func assert(_ condition: Bool, _ message: String, file: String = #file, line: Int = #line) {
    if condition {
        passed += 1
    } else {
        failed += 1
        print("FAIL [\(file.split(separator: "/").last ?? ""):\(line)] \(message)")
    }
}

// MARK: - Usage Parsing

func testParseBasicUsage() {
    let json: [String: Any] = [
        "five_hour": ["utilization": 20.0, "resets_at": "2026-07-10T19:00:00Z"],
        "seven_day": ["utilization": 82.0, "resets_at": "2026-07-14T06:00:00Z"],
    ]
    let r = ParsedUsage.parse(json, source: "Keychain")
    assert(r.fiveHour.utilization == 20.0, "five_hour utilization")
    assert(r.sevenDay.utilization == 82.0, "seven_day utilization")
    assert(r.fiveHour.resetsAt != nil, "five_hour resetsAt present")
    assert(r.sevenDay.resetsAt != nil, "seven_day resetsAt present")
    assert(r.cookieSource == "Keychain", "cookie source")
    assert(r.extra.isEmpty, "no extra windows")
}

func testParseWithExtraWindows() {
    let json: [String: Any] = [
        "five_hour": ["utilization": 10.0],
        "seven_day": ["utilization": 50.0],
        "extra_usage": ["utilization": 61.0],
    ]
    let r = ParsedUsage.parse(json, source: "Firefox")
    assert(r.extra.count == 1, "one extra window")
    assert(r.extra[0].label == "Extra Usage", "extra label is 'Extra Usage'")
    assert(r.extra[0].window.utilization == 61.0, "extra utilization")
}

func testAmberLadderIsExcluded() {
    let json: [String: Any] = [
        "five_hour": ["utilization": 10.0],
        "seven_day": ["utilization": 50.0],
        "amber_ladder": ["utilization": 0.0, "resets_at": "2026-07-10T08:00:00Z"],
    ]
    let r = ParsedUsage.parse(json, source: "Keychain")
    assert(r.extra.isEmpty, "amber_ladder excluded")
}

func testParseFractionalSecondsDate() {
    let json: [String: Any] = [
        "five_hour": ["utilization": 5.0, "resets_at": "2026-07-10T19:00:00.123456Z"],
        "seven_day": ["utilization": 10.0],
    ]
    let r = ParsedUsage.parse(json, source: "Chrome")
    assert(r.fiveHour.resetsAt != nil, "fractional seconds parsed")
}

func testParseMissingWindowDefaultsToZero() {
    let json: [String: Any] = [:]
    let r = ParsedUsage.parse(json, source: "Keychain")
    assert(r.fiveHour.utilization == 0.0, "missing five_hour defaults to 0")
    assert(r.sevenDay.utilization == 0.0, "missing seven_day defaults to 0")
    assert(r.fiveHour.resetsAt == nil, "missing five_hour has no reset date")
}

func testExtraWindowsSortResetBeforeNoReset() {
    let json: [String: Any] = [
        "five_hour": ["utilization": 0.0],
        "seven_day": ["utilization": 0.0],
        "no_reset_window": ["utilization": 30.0],
        "has_reset_window": ["utilization": 20.0, "resets_at": "2026-07-10T12:00:00Z"],
    ]
    let r = ParsedUsage.parse(json, source: "Keychain")
    assert(r.extra.count == 2, "two extra windows")
    assert(r.extra[0].label == "Has Reset Window", "window with reset sorts first")
    assert(r.extra[1].label == "No Reset Window", "window without reset sorts second")
}

func testNonWindowKeysAreIgnored() {
    let json: [String: Any] = [
        "five_hour": ["utilization": 10.0],
        "seven_day": ["utilization": 50.0],
        "some_string": "not a window",
        "some_number": 42,
        "dict_no_util": ["other_key": "value"],
    ]
    let r = ParsedUsage.parse(json, source: "Keychain")
    assert(r.extra.isEmpty, "non-window keys ignored")
}

// MARK: - Reset Countdown Formatting

func testFormatMinutesOnly() {
    assert(formatResetCountdown(seconds: 720) == "12m", "12 minutes")
}

func testFormatHoursAndMinutes() {
    assert(formatResetCountdown(seconds: 3900) == "1h 5m", "1h 5m")
}

func testFormatDaysHoursMinutes() {
    assert(formatResetCountdown(seconds: 97920) == "1d 3h 12m", "1d 3h 12m")
}

func testFormatZeroSeconds() {
    assert(formatResetCountdown(seconds: 0) == "0m", "zero seconds")
}

func testFormatExactlyOneDay() {
    assert(formatResetCountdown(seconds: 86400) == "1d 0h 0m", "exactly one day")
}

func testFormatExactlyOneHour() {
    assert(formatResetCountdown(seconds: 3600) == "1h 0m", "exactly one hour")
}

// MARK: - Run

testParseBasicUsage()
testParseWithExtraWindows()
testAmberLadderIsExcluded()
testParseFractionalSecondsDate()
testParseMissingWindowDefaultsToZero()
testExtraWindowsSortResetBeforeNoReset()
testNonWindowKeysAreIgnored()
testFormatMinutesOnly()
testFormatHoursAndMinutes()
testFormatDaysHoursMinutes()
testFormatZeroSeconds()
testFormatExactlyOneDay()
testFormatExactlyOneHour()

print("\n\(passed + failed) tests: \(passed) passed, \(failed) failed")
if failed > 0 { exit(1) }
