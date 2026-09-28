import Testing

@testable import AlulaConfig

@Suite("Configuration.positive… helpers")
struct PositiveValueTests {
    private func config(_ values: [String: String]) -> Configuration {
        Configuration(values: values)
    }

    @Test("an integer: absent is nil, positive is kept, zero or less is refused naming the key")
    func positiveInt() throws {
        #expect(try config([:]).positive("a.count") == nil)
        #expect(try config(["a.count": "3"]).positive("a.count") == 3)
        #expect(try config(["old.count": "4"]).positive("a.count", formerly: ["old.count"]) == 4)
        for value in ["0", "-2"] {
            let error = #expect(throws: NonPositiveConfigValue.self) {
                try config(["a.count": value]).positive("a.count")
            }
            #expect(error?.description == "a.count must be positive; it is \(value)")
        }
        // Malformed is still the decoding error, not this one.
        #expect(throws: ConfigError.self) { try config(["a.count": "three"]).positive("a.count") }
    }

    @Test("seconds: fractions kept; zero, negative, inf, nan and huge refused")
    func positiveSeconds() throws {
        #expect(try config([:]).positiveSeconds("a.seconds") == nil)
        #expect(try config(["a.seconds": "0.25"]).positiveSeconds("a.seconds") == .milliseconds(250))
        #expect(try config(["a.seconds": "30"]).positiveSeconds("a.seconds") == .seconds(30))
        for value in ["0", "-1", "inf", "-inf", "nan", "1e300"] {
            #expect(throws: NonPositiveConfigValue.self, "\(value)") {
                try config(["a.seconds": value]).positiveSeconds("a.seconds")
            }
        }
    }

    @Test("orThrow: the module's own error type")
    func wrapped() {
        struct ModuleError: Error { let message: String }
        let error = #expect(throws: ModuleError.self) {
            try config(["a.seconds": "inf"]).positiveSeconds(
                "a.seconds", orThrow: { ModuleError(message: $0.description) })
        }
        #expect(error?.message == "a.seconds must be positive; it is inf")
    }

    @Test("seconds or disabled: absent is nil, 0 or less is off, non-finite is refused")
    func secondsOrDisabled() throws {
        #expect(try config([:]).secondsOrDisabled("a.timeout") == nil)
        #expect(try config(["a.timeout": "0"]).secondsOrDisabled("a.timeout") == .some(nil))
        #expect(try config(["a.timeout": "-1"]).secondsOrDisabled("a.timeout") == .some(nil))
        #expect(try config(["a.timeout": "1.5"]).secondsOrDisabled("a.timeout") == .milliseconds(1500))
        for value in ["inf", "nan", "1e300"] {
            #expect(throws: NonPositiveConfigValue.self, "\(value)") {
                try config(["a.timeout": value]).secondsOrDisabled("a.timeout")
            }
        }
    }
}
