import Foundation

/// IMF-fixdate formatting and three-format parsing (RFC 9110 §5.6.7),
/// hand-rolled: `DateFormatter` is not `Sendable`, allocates per use, and
/// has Linux locale quirks — while an HTTP date is pure integer arithmetic
/// in a fixed calendar. Conversions use the standard civil-date algorithms.
///
/// AlulaWeb's public `HTTPDate` and the HTTP client's `Retry-After` parser
/// both read dates through this one; the client used to build three
/// `DateFormatter`s per call.
package enum HTTPDateCodec {
    private static let months = [
        "Jan", "Feb", "Mar", "Apr", "May", "Jun",
        "Jul", "Aug", "Sep", "Oct", "Nov", "Dec",
    ]
    private static let weekdays = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"]

    /// `Sun, 06 Nov 1994 08:49:37 GMT`
    package static func format(_ date: Date) -> String {
        let seconds = Int64(date.timeIntervalSince1970.rounded(.down))
        let days = seconds.quotientFlooring(86_400)
        let secondOfDay = seconds - days * 86_400
        let (year, month, day) = civil(fromDays: days)
        let weekday = weekdays[Int((days % 7 + 11) % 7)]  // 1970-01-01 = Thursday
        return String(
            format: "%@, %02d %@ %04d %02d:%02d:%02d GMT",
            weekday, day, months[month - 1], year,
            secondOfDay / 3_600, (secondOfDay / 60) % 60, secondOfDay % 60)
    }

    /// Accepts the three obs-forms every server must read: IMF-fixdate,
    /// RFC 850, and asctime.
    package static func parse(_ raw: String) -> Date? {
        let tokens = raw.split(whereSeparator: { $0 == " " || $0 == "," }).map(String.init)
        switch tokens.count {
        case 6 where tokens[5] == "GMT":
            // IMF: ["Sun", "06", "Nov", "1994", "08:49:37", "GMT"]
            guard let day = Int(tokens[1]), let month = month(tokens[2]),
                let year = Int(tokens[3]), let time = clock(tokens[4])
            else { return nil }
            return date(year: year, month: month, day: day, time: time)
        case 4 where tokens[3] == "GMT":
            // RFC 850: ["Sunday", "06-Nov-94", "08:49:37", "GMT"]
            let dateParts = tokens[1].split(separator: "-").map(String.init)
            guard dateParts.count == 3, let day = Int(dateParts[0]),
                let month = month(dateParts[1]), let shortYear = Int(dateParts[2]),
                (0...99).contains(shortYear), let time = clock(tokens[2])
            else { return nil }
            let year = shortYear >= 70 ? 1900 + shortYear : 2000 + shortYear
            return date(year: year, month: month, day: day, time: time)
        case 5:
            // asctime: ["Sun", "Nov", "6", "08:49:37", "1994"]
            guard let month = month(tokens[1]), let day = Int(tokens[2]),
                let time = clock(tokens[3]), let year = Int(tokens[4])
            else { return nil }
            return date(year: year, month: month, day: day, time: time)
        default:
            return nil
        }
    }

    private static func month(_ token: String) -> Int? {
        months.firstIndex(of: token).map { $0 + 1 }
    }

    private static func clock(_ token: String) -> (Int, Int, Int)? {
        let parts = token.split(separator: ":").compactMap { Int($0) }
        guard parts.count == 3,
            (0...23).contains(parts[0]), (0...59).contains(parts[1]), (0...60).contains(parts[2])
        else { return nil }
        return (parts[0], parts[1], parts[2])
    }

    private static func date(year: Int, month: Int, day: Int, time: (Int, Int, Int)) -> Date? {
        // The year is a client's number, parsed as far as Int goes, and the
        // civil-date arithmetic below overflowed on one like 999999999999 —
        // a trap from any If-Modified-Since header. Four digits is what the
        // grammar allows (RFC 9110 §5.6.7).
        guard (0...9999).contains(year), (1...12).contains(month), (1...31).contains(day)
        else { return nil }
        let days = days(fromCivilYear: year, month: month, day: day)
        let seconds = days * 86_400 + Int64(time.0) * 3_600 + Int64(time.1) * 60 + Int64(time.2)
        return Date(timeIntervalSince1970: TimeInterval(seconds))
    }

    // Howard Hinnant's civil-date algorithms — exact over the proleptic
    // Gregorian calendar, no lookup tables, no Foundation.
    private static func days(fromCivilYear y: Int, month m: Int, day d: Int) -> Int64 {
        let y = Int64(m <= 2 ? y - 1 : y)
        let era = (y >= 0 ? y : y - 399).quotientFlooring(400)
        let yoe = y - era * 400
        let doy = Int64((153 * (m + (m > 2 ? -3 : 9)) + 2) / 5 + d - 1)
        let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy
        return era * 146_097 + doe - 719_468
    }

    private static func civil(fromDays z: Int64) -> (year: Int, month: Int, day: Int) {
        let z = z + 719_468
        let era = (z >= 0 ? z : z - 146_096).quotientFlooring(146_097)
        let doe = z - era * 146_097
        let yoe = (doe - doe / 1_460 + doe / 36_524 - doe / 146_096) / 365
        let y = yoe + era * 400
        let doy = doe - (365 * yoe + yoe / 4 - yoe / 100)
        let mp = (5 * doy + 2) / 153
        let d = doy - (153 * mp + 2) / 5 + 1
        let m = mp < 10 ? mp + 3 : mp - 9
        return (Int(m <= 2 ? y + 1 : y), Int(m), Int(d))
    }
}

extension Int64 {
    /// Floor division — Swift's `/` truncates toward zero, and every date
    /// algorithm above needs the mathematical floor for negative values.
    fileprivate func quotientFlooring(_ divisor: Int64) -> Int64 {
        let q = self / divisor
        return (self % divisor != 0 && (self < 0) != (divisor < 0)) ? q - 1 : q
    }
}
