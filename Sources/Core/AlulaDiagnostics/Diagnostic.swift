/// A framework-owned diagnostic: what is wrong, where, why, and what to do.
///
/// Every failure Alula understands — a missing provider, a composition
/// cycle, a route it cannot bind — is reported as one of these, not as a
/// Swift type error in generated code. It renders in the compiler's own
/// format, so an IDE attaches it to the developer's line:
///
/// ```text
/// Sources/App/Billing.swift:8:17: error: [ALU-DI-1001] no module provides `PaymentClient`
///     dependency path:
///       CheckoutController → CheckoutService → PaymentClient
///     help: a module that owns a `PaymentClient` exposes it as a stored property.
///     docs: https://…/ALU-DI-1001.md
/// Sources/App/Stripe.swift:4:1: note: `StripeModule.client` has no written type …
/// ```
///
/// The first line is the whole message an issue navigator shows, so it
/// carries the code and a one-line summary; the indented lines are the
/// explanation a build log shows beneath it.
public struct Diagnostic: Sendable, Equatable {
    public enum Severity: String, Sendable, Equatable {
        case error, warning, note
    }

    /// A related location with its own one-line message: the other provider,
    /// the first declaration of a duplicate.
    public struct Note: Sendable, Equatable {
        public let message: String
        public let location: DiagnosticLocation?

        public init(_ message: String, at location: DiagnosticLocation? = nil) {
            self.message = message
            self.location = location
        }
    }

    public let code: DiagnosticCode
    public let severity: Severity
    /// One line, in the application's terms: "no module provides `Mailer`".
    public let summary: String
    public let location: DiagnosticLocation?
    /// Context worth showing whole — a dependency path, a cycle, candidates —
    /// one entry per line, indented under the summary.
    public let context: [String]
    /// The rule in a sentence or two. Short: the docs page teaches.
    public let explanation: [String]
    /// What to do next. Each entry may span lines (a snippet to paste).
    public let help: [String]
    public let notes: [Note]

    public init(
        _ code: DiagnosticCode,
        severity: Severity? = nil,
        _ summary: String,
        at location: DiagnosticLocation?,
        context: [String] = [],
        explanation: [String] = [],
        help: [String] = [],
        notes: [Note] = []
    ) {
        self.code = code
        self.severity = severity ?? code.severity
        self.summary = summary
        self.location = location
        self.context = context
        self.explanation = explanation
        self.help = help
        self.notes = notes
    }

    /// The compiler-format text: a `path:line:column: severity:` line that
    /// build tools and IDEs parse, then the indented body, then one located
    /// `note:` line per related location.
    public var rendered: String {
        var lines = [header(severity.rawValue, "[\(code.id)] \(summary)", at: location)]
        let indent = "    "
        for line in context { lines.append(indent + line) }
        for line in explanation { lines.append(indent + line) }
        for entry in help {
            let parts = entry.split(separator: "\n", omittingEmptySubsequences: false)
            lines.append(indent + "help: " + (parts.first.map(String.init) ?? ""))
            for part in parts.dropFirst() { lines.append(indent + "      " + part) }
        }
        lines.append(indent + "docs: " + code.documentationURL)
        for note in notes {
            lines.append(header("note", note.message, at: note.location))
        }
        return lines.joined(separator: "\n")
    }

    private func header(_ severity: String, _ message: String, at location: DiagnosticLocation?) -> String {
        guard let location else { return "\(severity): \(message)" }
        return "\(location.file):\(location.line):\(location.column): \(severity): \(message)"
    }
}

/// A point in the developer's source: never a generated file.
public struct DiagnosticLocation: Sendable, Equatable, Hashable, CustomStringConvertible {
    public let file: String
    public let line: Int
    public let column: Int

    public init(file: String, line: Int, column: Int = 1) {
        self.file = file
        self.line = line
        self.column = max(1, column)
    }

    public var description: String { "\(file):\(line):\(column)" }
}
