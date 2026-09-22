import Testing

@testable import FlightSecurityCore

/// Runs against the real Argon2 reference implementation, deliberately.
/// This is exactly the kind of thing a mock would hide the truth about: the
/// C interop is the part with no other test coverage, and a fake hasher
/// proves nothing about whether the actual library call, buffer sizing, and
/// error mapping are correct.
///
/// Cost parameters are turned down from ``Argon2idHashing/Parameters/owaspDefault``
/// everywhere here — the algorithm's whole point is to be slow, and a suite
/// that pays the real cost on every hash would be the one file that makes
/// `swift test` slow. Correctness does not depend on the cost parameters;
/// only wall-clock time does.
@Suite("Argon2idHashing")
struct Argon2idHashingTests {
    private let fast = Argon2idHashing(
        parameters: Argon2idHashing.Parameters(timeCost: 1, memoryCost: 8, parallelism: 1))

    @Test("a hash round-trips: the same password verifies against it")
    func roundTrip() throws {
        let hash = try fast.hash("correct horse battery staple")
        #expect(fast.verify("correct horse battery staple", against: hash))
    }

    @Test("the wrong password does not verify")
    func wrongPasswordFails() throws {
        let hash = try fast.hash("correct horse battery staple")
        #expect(!fast.verify("wrong password entirely", against: hash))
        #expect(
            !fast.verify("correct horse battery staplE", against: hash), "not even by one character"
        )
    }

    @Test("the produced string is a self-describing argon2id PHC string")
    func encodedShape() throws {
        let hash = try fast.hash("a password")
        #expect(hash.hasPrefix("$argon2id$v="))
        #expect(hash.contains("$m=8,t=1,p=1$"))
        // Two more `$`-delimited fields follow: salt, then hash, both base64.
        #expect(hash.split(separator: "$", omittingEmptySubsequences: true).count == 5)
    }

    @Test("hashing the same password twice produces two different strings, both valid")
    func saltIsRandomPerCall() throws {
        let first = try fast.hash("same password")
        let second = try fast.hash("same password")
        #expect(first != second, "a fixed salt would make identical passwords identically stored")
        #expect(fast.verify("same password", against: first))
        #expect(fast.verify("same password", against: second))
    }

    @Test("an empty password is accepted: length policy is not this type's job")
    func emptyPasswordAccepted() throws {
        let hash = try fast.hash("")
        #expect(fast.verify("", against: hash))
        #expect(!fast.verify("not empty", against: hash))
    }

    @Test("a password holding non-ASCII text round-trips as UTF-8 bytes")
    func unicodePassword() throws {
        let password = "pässwörd 🔒 with unicode"
        let hash = try fast.hash(password)
        #expect(fast.verify(password, against: hash))
    }

    // MARK: verify against garbage

    @Test("verify answers false, never throws, for a hash that is not valid at all")
    func verifyAgainstGarbage() {
        #expect(!fast.verify("anything", against: ""))
        #expect(!fast.verify("anything", against: "not a hash"))
        #expect(!fast.verify("anything", against: "$argon2id$v=19$m=8,t=1,p=1$short$short"))
    }

    @Test("verify answers false for a hash a different algorithm variant produced")
    func verifyAgainstWrongVariant() throws {
        // argon2id_verify is variant-specific by construction; a real
        // argon2i or argon2d string must not verify through the id path.
        let looksLikeArgon2i = "$argon2i$v=19$m=8,t=1,p=1$c29tZXNhbHQ$aGFzaGVkdmFsdWU"
        #expect(!fast.verify("anything", against: looksLikeArgon2i))
    }

    // MARK: needsRehash

    @Test("a hash made with the current parameters does not need rehashing")
    func needsRehashFalseForCurrent() throws {
        let hash = try fast.hash("a password")
        #expect(!fast.needsRehash(hash))
    }

    @Test("a hash made with weaker parameters needs rehashing")
    func needsRehashTrueForWeaker() throws {
        let weak = Argon2idHashing(
            parameters: Argon2idHashing.Parameters(timeCost: 1, memoryCost: 8, parallelism: 1))
        let strong = Argon2idHashing(
            parameters: Argon2idHashing.Parameters(timeCost: 2, memoryCost: 16, parallelism: 1))
        let hash = try weak.hash("a password")
        #expect(strong.needsRehash(hash))
        #expect(!weak.needsRehash(hash))
    }

    @Test("needsRehash is true for a string it cannot parse, rather than throwing")
    func needsRehashTrueForUnparseable() {
        #expect(fast.needsRehash(""))
        #expect(fast.needsRehash("not a hash at all"))
        #expect(fast.needsRehash("$argon2id$v=19$missing-params$salt$hash"))
    }

    // MARK: The real cost, once

    @Test("the OWASP default produces a hash real code would actually store")
    func owaspDefaultProducesAValidHash() throws {
        // The one test allowed to pay the real cost, so the default
        // parameters themselves are proven to work, not just the fast ones
        // every other test uses.
        let hasher = Argon2idHashing()
        let hash = try hasher.hash("a realistic password")
        #expect(hasher.verify("a realistic password", against: hash))
        #expect(hash.contains("$m=19456,t=2,p=1$"))
    }
}
