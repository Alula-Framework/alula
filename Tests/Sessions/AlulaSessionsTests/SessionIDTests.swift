import AlulaSessions
import Testing

@Suite("SessionID")
struct SessionIDTests {

    @Test("a generated id is 43 characters of unpadded base64url")
    func shape() {
        let id = SessionID.generate()
        #expect(id.cookieValue.count == 43)
        #expect(!id.cookieValue.contains("="))
        #expect(!id.cookieValue.contains("+"))
        #expect(!id.cookieValue.contains("/"))
        #expect(id.cookieValue.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" })
    }

    @Test("two generated ids differ")
    func distinct() {
        // 256 bits of entropy: a collision here is a broken generator, not
        // bad luck.
        let ids = Set((0..<64).map { _ in SessionID.generate() })
        #expect(ids.count == 64)
    }

    @Test("a generated id round-trips through its cookie value")
    func roundTrip() {
        let id = SessionID.generate()
        #expect(SessionID(cookieValue: id.cookieValue) == id)
    }

    @Test("anything that is not the generated shape is rejected")
    func rejects() {
        #expect(SessionID(cookieValue: "") == nil)
        #expect(SessionID(cookieValue: "short") == nil)
        #expect(SessionID(cookieValue: String(repeating: "a", count: 42)) == nil)
        #expect(SessionID(cookieValue: String(repeating: "a", count: 44)) == nil)
        // Right length, wrong alphabet — a padding character, a plus sign.
        #expect(SessionID(cookieValue: String(repeating: "a", count: 42) + "=") == nil)
        #expect(SessionID(cookieValue: String(repeating: "a", count: 42) + "+") == nil)
        // Right length in characters, wrong in bytes.
        #expect(SessionID(cookieValue: String(repeating: "é", count: 43)) == nil)
    }

    @Test("the description is redacted; the cookie value is not")
    func redacted() {
        let id = SessionID.generate()
        #expect(String(describing: id).count < id.cookieValue.count)
        #expect(id.cookieValue.hasPrefix(String(describing: id).dropLast()))
    }
}
