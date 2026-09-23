import CArgon2

/// ``PasswordHashing`` over Argon2id, the OWASP-recommended default and the
/// winner of the Password Hashing Competition (RFC 9106).
///
/// The cryptography is entirely the reference implementation's — the actual
/// C source the algorithm's own designers publish and every other
/// language's bindings wrap, not a Swift reimplementation. This type is
/// orchestration around it: turning `String` into the bytes the C API
/// wants, generating the salt, and reading its own parameters back out of
/// what it produced. The same division JWTKit draws for JWT signatures and
/// `swift-certificates` draws for X.509: the primitive is delegated, Alula
/// owns the policy around it.
///
/// Argon2*id* specifically, not Argon2i or Argon2d — the hybrid variant,
/// resistant to both the side-channel attacks Argon2i defends against and
/// the GPU-cracking attacks Argon2d defends against, which is why it is the
/// one OWASP recommends without qualification.
public struct Argon2idHashing: PasswordHashing {

    /// The cost parameters, and how much salt and output to use.
    ///
    /// Read the algorithm's own naming rather than Alula's elsewhere:
    /// `timeCost` is iterations, `memoryCost` is kibibytes, both because
    /// that is what the RFC and every operational guide about tuning them
    /// calls them, and translating would only make the two harder to read
    /// side by side.
    public struct Parameters: Sendable, Equatable {
        /// Iterations. RFC 9106 calls this `t`.
        public var timeCost: UInt32
        /// Memory in kibibytes. RFC 9106 calls this `m`. The dominant cost:
        /// this is what actually makes a hash expensive to brute-force in
        /// parallel, since an attacker needs this much memory *per guess in
        /// alula*, not just this much time.
        public var memoryCost: UInt32
        /// Threads and compute lanes. RFC 9106 calls this `p`.
        public var parallelism: UInt32
        /// Salt bytes. 16 is RFC 9106's recommendation and the library's
        /// own default; there is no reason to move it.
        public var saltLength: Int
        /// Hash bytes. 32 is standard and gives 256 bits of output.
        public var hashLength: Int

        public init(
            timeCost: UInt32, memoryCost: UInt32, parallelism: UInt32,
            saltLength: Int = 16, hashLength: Int = 32
        ) {
            self.timeCost = timeCost
            self.memoryCost = memoryCost
            self.parallelism = parallelism
            self.saltLength = saltLength
            self.hashLength = hashLength
        }

        /// OWASP's first-choice profile: memory-dominant, one thread. 19
        /// MiB and two passes is deliberately the *floor* OWASP states
        /// server hardware should clear easily — this is a default meant
        /// to be raised, not a ceiling.
        public static let owaspDefault = Parameters(timeCost: 2, memoryCost: 19456, parallelism: 1)
    }

    public let parameters: Parameters

    public init(parameters: Parameters = .owaspDefault) {
        self.parameters = parameters
    }

    public func hash(_ password: String) throws -> String {
        var passwordBytes = Array(password.utf8)
        var salt = Self.randomSalt(count: parameters.saltLength)

        let encodedLength = argon2_encodedlen(
            parameters.timeCost, parameters.memoryCost, parameters.parallelism,
            UInt32(parameters.saltLength), UInt32(parameters.hashLength), Argon2_id)
        var encoded = [CChar](repeating: 0, count: encodedLength)

        let result = argon2id_hash_encoded(
            parameters.timeCost, parameters.memoryCost, parameters.parallelism,
            &passwordBytes, passwordBytes.count,
            &salt, salt.count,
            parameters.hashLength,
            &encoded, encoded.count)
        guard result == ARGON2_OK.rawValue else {
            throw PasswordHashingError(reason: Self.errorMessage(result))
        }
        // The pointer-taking initializer, not the deprecated one that takes
        // an `Array` directly: `encoded` really is a null-terminated C
        // string the library just wrote, and this reads it as one.
        return encoded.withUnsafeBufferPointer { String(cString: $0.baseAddress!) }
    }

    public func verify(_ password: String, against hash: String) -> Bool {
        var passwordBytes = Array(password.utf8)
        return hash.withCString { encoded in
            argon2id_verify(encoded, &passwordBytes, passwordBytes.count) == ARGON2_OK.rawValue
        }
    }

    public func needsRehash(_ hash: String) -> Bool {
        // A hash this parser does not recognize is treated as needing a
        // rehash rather than reported as an error: the only place this is
        // called from is right after a successful `verify`, so the worst
        // outcome of guessing wrong here is one unnecessary rehash on the
        // next sign-in, never a security gap.
        guard let stored = Self.parseParameters(hash) else { return true }
        return stored.timeCost != parameters.timeCost || stored.memoryCost != parameters.memoryCost
            || stored.parallelism != parameters.parallelism
    }

    // MARK: - The encoded string

    /// Pulls `m=…,t=…,p=…` out of `$argon2id$v=19$m=…,t=…,p=…$salt$hash`.
    /// Everything here is Alula's own, deliberately minimal parsing of a
    /// string Alula itself produced — this is not a general PHC
    /// string-format parser, and it does not need to be one.
    private static func parseParameters(_ hash: String) -> Parameters? {
        let fields = hash.split(separator: "$", omittingEmptySubsequences: true)
        guard fields.count >= 3, fields[0] == "argon2id" else { return nil }
        var timeCost: UInt32?
        var memoryCost: UInt32?
        var parallelism: UInt32?
        for pair in fields[2].split(separator: ",") {
            let parts = pair.split(separator: "=", maxSplits: 1)
            guard parts.count == 2, let value = UInt32(parts[1]) else { continue }
            switch parts[0] {
            case "m": memoryCost = value
            case "t": timeCost = value
            case "p": parallelism = value
            default: continue
            }
        }
        guard let timeCost, let memoryCost, let parallelism else { return nil }
        return Parameters(timeCost: timeCost, memoryCost: memoryCost, parallelism: parallelism)
    }

    // MARK: - Salt

    /// `SystemRandomNumberGenerator`, the same source `SessionID.generate()`
    /// uses: cryptographically secure on every platform Swift ships on.
    private static func randomSalt(count: Int) -> [UInt8] {
        var generator = SystemRandomNumberGenerator()
        var bytes: [UInt8] = []
        bytes.reserveCapacity(count)
        for _ in 0..<count {
            bytes.append(UInt8.random(in: .min ... .max, using: &generator))
        }
        return bytes
    }

    private static func errorMessage(_ code: Int32) -> String {
        String(cString: argon2_error_message(code))
    }
}
