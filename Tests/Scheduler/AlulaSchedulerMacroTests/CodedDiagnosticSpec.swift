import AlulaDiagnostics
import SwiftDiagnostics
import SwiftSyntaxMacrosGenericTestSupport

extension DiagnosticSpec {
    /// An Alula macro diagnostic as it reaches the reader: the message leads
    /// with the code, the severity is the code's, and a note at the same
    /// place links the code's page.
    static func coded(
        _ code: DiagnosticCode,
        message: String,
        line: Int,
        column: Int,
        fixIts: [FixItSpec] = [],
        originatorFileID: StaticString = #fileID,
        originatorFile: StaticString = #filePath,
        originatorLine: UInt = #line,
        originatorColumn: UInt = #column
    ) -> DiagnosticSpec {
        DiagnosticSpec(
            message: "[\(code.id)] \(message)",
            line: line,
            column: column,
            severity: code.severity == .warning ? .warning : .error,
            notes: [
                NoteSpec(
                    message: "see \(code.documentationURL)", line: line, column: column,
                    originatorFileID: originatorFileID, originatorFile: originatorFile,
                    originatorLine: originatorLine, originatorColumn: originatorColumn)
            ],
            fixIts: fixIts,
            originatorFileID: originatorFileID,
            originatorFile: originatorFile,
            originatorLine: originatorLine,
            originatorColumn: originatorColumn)
    }
}
