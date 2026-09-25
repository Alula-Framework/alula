import Foundation
import HTTPTypes
import Testing

@testable import AlulaWeb

// Every parser that reads text a client controls, fed inputs built from the
// pieces that have broken parsers before: numbers at and past Int64's edges,
// separators alone, quotes, Unicode digits, truncated escapes.
//
// The assertion is the absence of a trap. Four remote crashes were found in
// one afternoon — a Range end of Int64.max, a date with a twelve-digit year,
// an Accept-Encoding entry of ";", a gossip counter of UInt64.max — and each
// was one input nobody had thought to write down. A test that writes down
// thousands of them, reproducibly, is the cheap half of not finding the next
// one in production. The seed is fixed, so a failure reproduces exactly.

/// SplitMix64: small, fast, and the same sequence on every platform.
private struct Seeded: RandomNumberGenerator {
    var state: UInt64
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

private let pieces: [String] = [
    "", " ", ",", ";", "=", "-", ":", "\"", "*", "/", "W/", "q=", "q=0", "q=1.0", "q=-1",
    "0", "1", "9", "70", "99", "100", "26", "25", "27",
    "9223372036854775807", "9223372036854775808", "-9223372036854775808",
    "18446744073709551615", "999999999999", "-1", "+1", "1e400", "nan", "inf",
    "٣", "１", "\u{0}", "\u{7F}", "é", "\r\n", "%", "%Z", "%ZZ", "%00", "&", "+",
    "bytes=", "Bytes=", "bytes", "gzip", "br", "identity", "deflate",
    "Sun", "Sunday", "Nov", "Feb", "GMT", "UTC", "06", "-Nov-", "08:49:37", "24:00:00", "99:99:99",
    "text/html", "application/json", "*/*", "charset=utf-8", "boundary=", "form-data", "name=", "filename=",
    "abc", "YWJj", "==", "Bearer", "Basic", "\u{202E}",
]

private func fuzzInput(_ rng: inout Seeded) -> String {
    let length = Int.random(in: 0...10, using: &rng)
    return (0..<length).map { _ in pieces.randomElement(using: &rng)! }.joined()
}

/// Numbers at the edges that matter: small, around the test sizes, and at
/// and past the limits of Int64 and UInt64.
private let numbers: [String] = [
    "0", "1", "2", "25", "26", "27", "99", "100", "1970", "9999", "10000",
    "999999999999", "9223372036854775806", "9223372036854775807", "9223372036854775808",
    "18446744073709551615", "-1", "-9223372036854775808", "", "٣", "1e3",
]

private func number(_ rng: inout Seeded) -> String { numbers.randomElement(using: &rng)! }

/// Inputs in the shape a parser expects, with fuzzed fields — random joins
/// alone almost never produce `bytes=<n>-<n>` or a six-token date, which is
/// exactly where the arithmetic was.
private func shaped(_ count: Int, seed: UInt64, _ make: (inout Seeded) -> String) -> [String] {
    var rng = Seeded(state: seed)
    return (0..<count).map { _ in make(&rng) }
}

private func corpus(_ count: Int, seed: UInt64) -> [String] {
    var rng = Seeded(state: seed)
    // The pieces alone, then random joins of them.
    return pieces + (0..<count).map { _ in fuzzInput(&rng) }
}

@Suite("Parsers survive adversarial input")
struct ParserFuzzTests {
    private let sizes: [Int64] = [0, 1, 26, Int64.max - 1, Int64.max]

    @Test("Range: parsing and resolving never trap, and satisfiable ranges stay in bounds")
    func range() {
        let ranges = shaped(4_000, seed: 11) { rng in
            switch Int.random(in: 0...2, using: &rng) {
            case 0: "bytes=\(number(&rng))-\(number(&rng))"
            case 1: "bytes=\(number(&rng))-"
            default: "bytes=-\(number(&rng))"
            }
        }
        for input in corpus(4_000, seed: 1) + ranges {
            guard let range = RequestedByteRange(input) else { continue }
            for size in sizes {
                if case .satisfiable(let r) = range.resolve(against: size) {
                    #expect(r.lowerBound >= 0 && r.upperBound <= size && !r.isEmpty, "\(input.debugDescription)")
                }
            }
        }
    }

    @Test("HTTP dates: every form, never a trap, and any date parsed is within the grammar's years")
    func dates() {
        let dates = shaped(4_000, seed: 13) { rng in
            let day = number(&rng), year = number(&rng)
            let time = Bool.random(using: &rng) ? "08:49:37" : "\(number(&rng)):\(number(&rng)):\(number(&rng))"
            switch Int.random(in: 0...2, using: &rng) {
            case 0: return "Sun, \(day) Nov \(year) \(time) GMT"
            case 1: return "Sunday, \(day)-Nov-\(year) \(time) GMT"
            default: return "Sun Nov \(day) \(time) \(year)"
            }
        }
        for input in corpus(4_000, seed: 3) + dates {
            if let date = HTTPDate.parse(input) {
                // 0000-01-01 … 9999-12-31, the four-digit years RFC 9110 allows.
                #expect(date.timeIntervalSince1970 >= -62_167_219_200 && date.timeIntervalSince1970 < 253_402_300_800)
            }
        }
    }

    @Test("entity tags, Accept-Encoding, media types and disposition parameters never trap")
    func headerLists() {
        for input in corpus(4_000, seed: 4) {
            _ = EntityTag.parseOne(input)
            _ = ResponseCompression.negotiate(input)
            _ = AssetMountRegistration.acceptedEncodings(input)
            _ = MediaType(parsing: input)
            _ = ContentDisposition(parsing: input)
            _ = TusMount.parseMetadata(input)
        }
    }

    @Test("form bodies and cookies never trap")
    func bodiesAndCookies() throws {
        for input in corpus(3_000, seed: 5) {
            _ = try? FormParser.parse(Data(input.utf8))
            let request = Request(method: .get, path: "/", headers: [.cookie: input])
            _ = request.cookies
        }
    }

    /// The whole conditional-request path, with every validator header a
    /// client can send, against a real descriptor.
    @Test("serveContent never traps, whatever the conditional headers say")
    func serveContentHeaders() async throws {
        var rng = Seeded(state: 6)
        let descriptor = ContentDescriptor(
            source: DataByteSource(Data("abcdefghijklmnopqrstuvwxyz".utf8)),
            contentType: "text/plain",
            modificationDate: Date(timeIntervalSince1970: 1_700_000_000),
            etag: EntityTag("v1"))
        for _ in 0..<2_000 {
            var headers = HTTPFields()
            for field in [HTTPField.Name.range, .ifRange, .ifModifiedSince, .ifNoneMatch, .ifMatch, .ifUnmodifiedSince]
            where Bool.random(using: &rng) {
                headers[field] = fuzzInput(&rng)
            }
            let response = serveContent(
                for: Request(method: Bool.random(using: &rng) ? .get : .head, path: "/a", headers: headers),
                descriptor)
            #expect(response.status.code < 500)
        }
    }
}
