import CFlightZlib
import Foundation
import HTTPTypes

// Response compression.
//
// gzip only, deliberately. `deflate` is the trap it has always been: RFC 9110
// says the zlib format, a large minority of servers shipped raw DEFLATE, and
// clients learned to guess — so a server that offers it is choosing between
// two wire formats with one name. Nobody needs it: every client that sends
// `deflate` sends `gzip` too. Brotli is the one genuinely worth adding, and
// it needs its own system library, so it is a later additive case rather than
// a reason to hold this.

/// A content coding this service can produce.
public enum ContentEncoding: String, Sendable, CaseIterable {
    case gzip
}

/// How hard to work. zlib's levels, named for what they trade.
public enum CompressionLevel: Sendable {
    /// Level 1 — noticeably cheaper, a few points of ratio.
    case fastest
    /// Level 6, zlib's own default and the right answer almost always.
    case balanced
    /// Level 9 — markedly more CPU for very little size. Worth it only for
    /// something compressed once and served often, which is a static asset,
    /// which is not this.
    case smallest

    var zlibValue: Int32 {
        switch self {
        case .fastest: return 1
        case .balanced: return 6
        case .smallest: return 9
        }
    }
}

/// Incremental gzip over one response body.
///
/// Not `Sendable`, and not meant to be: one of these belongs to exactly one
/// body, used from the one task producing it. The streaming path creates it
/// inside its producer for that reason.
final class Deflater {
    private var stream = z_stream()
    private var isOpen = false
    /// 16 KiB: large enough that a typical JSON body finishes in one pass,
    /// small enough not to matter when thousands are in flight.
    private static let outputChunk = 16 * 1024

    init?(level: CompressionLevel) {
        // 15 window bits is zlib's maximum; +16 selects a gzip wrapper rather
        // than a zlib one. 8 is the memory level zlib documents as the
        // default trade.
        let status = deflateInit2_(
            &stream, level.zlibValue, Z_DEFLATED, 15 + 16, 8, Z_DEFAULT_STRATEGY,
            ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size))
        guard status == Z_OK else { return nil }
        isOpen = true
    }

    deinit {
        if isOpen { deflateEnd(&stream) }
    }

    /// Compresses `input`, returning whatever zlib chose to emit.
    ///
    /// With `.sync` the result is a complete, flushed block: a client can
    /// decode everything fed so far, which is what keeps server-sent events
    /// live rather than arriving in one lump at the end.
    func compress(_ input: Data, flush: Flush) -> Data {
        var input = input
        var output = Data()
        if input.isEmpty {
            // zlib tolerates a null `next_in` only with `avail_in == 0`,
            // which is exactly the flush-with-nothing-pending case.
            stream.next_in = nil
            stream.avail_in = 0
            drain(into: &output, flush: flush.zlibValue)
            return output
        }
        input.withUnsafeMutableBytes { raw in
            stream.next_in = raw.bindMemory(to: UInt8.self).baseAddress
            stream.avail_in = uInt(raw.count)
            drain(into: &output, flush: flush.zlibValue)
        }
        return output
    }

    /// Pumps zlib until it stops filling the output buffer — the standard
    /// loop. Stopping at the first partial buffer would strand bytes zlib
    /// still holds, which shows up as a truncated body only for inputs large
    /// enough to need a second pass.
    private func drain(into output: inout Data, flush: Int32) {
        var buffer = [UInt8](repeating: 0, count: Self.outputChunk)
        while true {
            let produced: Int = buffer.withUnsafeMutableBufferPointer { out in
                stream.next_out = out.baseAddress
                stream.avail_out = uInt(Self.outputChunk)
                let status = deflate(&stream, flush)
                guard status != Z_STREAM_ERROR else { return -1 }
                return Self.outputChunk - Int(stream.avail_out)
            }
            guard produced > 0 else { break }
            output.append(contentsOf: buffer[0..<produced])
            if produced < Self.outputChunk { break }
        }
    }

    enum Flush {
        /// Ends the stream. Nothing may be compressed afterwards.
        case finish
        /// Emits a complete block, leaving the stream open.
        case sync

        var zlibValue: Int32 {
            switch self {
            case .finish: return Z_FINISH
            case .sync: return Z_SYNC_FLUSH
            }
        }
    }
}

/// Compresses responses that are worth compressing, for clients that asked.
///
/// ```swift
/// MiddlewareRegistration.lane(.default, [ResponseCompression()])
/// ```
///
/// ## What it leaves alone, and why
///
/// - **Anything already carrying `Content-Encoding`.** `StaticAssets` serves
///   pre-built `.br`/`.gz` variants, which are better than anything computed
///   per request; compressing them again would produce gzip-wrapped brotli.
/// - **`.file` responses.** A range is a range *of the encoded
///   representation*, so compressing after the range was selected answers a
///   different question than the one asked. Static files are the case where
///   pre-compressing wins anyway.
/// - **Bodies under ``minimumBytes``.** gzip has ~20 bytes of framing and a
///   floor on what it can achieve; below a kilobyte or so it reliably makes
///   things bigger while costing CPU on both ends.
/// - **Types not in ``compressibleTypes``.** JPEG, PNG, zip and video are
///   already compressed; running deflate over them is pure waste.
/// - **Upgrades**, and statuses that carry no body.
///
/// A streaming body is compressed incrementally and flushed per chunk, so
/// server-sent events keep arriving as events rather than accumulating until
/// the stream ends.
public struct ResponseCompression: Middleware {
    /// The floor under which compressing costs more than it saves.
    public let minimumBytes: Int
    /// Media types worth compressing, matched as prefixes of the response's
    /// `Content-Type` — `"text/"` covers all of it, `"application/json"`
    /// matches `application/json; charset=utf-8`.
    public let compressibleTypes: [String]
    public let level: CompressionLevel

    /// The types that actually benefit. Everything else is left alone, which
    /// is the right default: the list of compressible types is short and
    /// knowable, the list of already-compressed ones is neither.
    public static let defaultCompressibleTypes = [
        "text/",
        "application/json",
        "application/problem+json",
        "application/javascript",
        "application/xml",
        "application/xhtml+xml",
        "application/yaml",
        "image/svg+xml",
    ]

    public init(
        minimumBytes: Int = 1024,
        compressibleTypes: [String] = ResponseCompression.defaultCompressibleTypes,
        level: CompressionLevel = .balanced
    ) {
        self.minimumBytes = minimumBytes
        self.compressibleTypes = compressibleTypes
        self.level = level
    }

    public func handle(_ context: RequestContext, next: Next) async throws -> Response {
        let accepted = Self.negotiate(context.request.headers[.acceptEncoding])
        let response = try await next(context)
        guard accepted == .gzip else {
            // Still varies: a cache that stored this uncompressed copy must
            // not hand it to a client that would have been sent gzip.
            return Self.vary(response)
        }
        guard response.headers[.contentEncoding] == nil,
            response.status != .partialContent,
            Self.statusAllowsBody(response.status)
        else { return Self.vary(response) }

        switch response {
        case .fixed(let status, let headers, let body):
            guard body.count >= minimumBytes, isCompressible(headers[.contentType]),
                let deflater = Deflater(level: level)
            else { return Self.vary(response) }
            let compressed = deflater.compress(body, flush: .finish)
            guard compressed.count < body.count else {
                // It grew. Rare above the floor, but incompressible data at
                // a compressible type (an already-gzipped JSON blob served as
                // application/json) does exactly this.
                return Self.vary(response)
            }
            return Self.vary(
                .fixed(status: status, headers: Self.encoded(headers), body: compressed))

        case .streaming(let status, let headers, let body):
            guard isCompressible(headers[.contentType]) else { return Self.vary(response) }
            let level = self.level
            let compressed = AsyncStream<Data> { continuation in
                let task = Task {
                    // Created here so the deflater never crosses a task
                    // boundary: one body, one producer, one z_stream.
                    guard let deflater = Deflater(level: level) else {
                        for await chunk in body { continuation.yield(chunk) }
                        continuation.finish()
                        return
                    }
                    for await chunk in body {
                        let out = deflater.compress(chunk, flush: .sync)
                        if !out.isEmpty { continuation.yield(out) }
                    }
                    let tail = deflater.compress(Data(), flush: .finish)
                    if !tail.isEmpty { continuation.yield(tail) }
                    continuation.finish()
                }
                continuation.onTermination = { _ in task.cancel() }
            }
            return Self.vary(
                .streaming(
                    status: status, headers: Self.encoded(headers), body: compressed))

        case .file, .upgrade:
            return Self.vary(response)
        }
    }

    private func isCompressible(_ contentType: String?) -> Bool {
        guard let contentType else { return false }
        let lowered = contentType.lowercased()
        return compressibleTypes.contains { lowered.hasPrefix($0.lowercased()) }
    }

    /// `Content-Encoding` on, `Content-Length` off (the transport recomputes
    /// it, and for a stream there is none), and any strong `ETag` weakened.
    ///
    /// The `ETag` part matters: a strong validator promises byte-for-byte
    /// identity, and the gzip of a body is not the body. Leaving it strong is
    /// what makes `If-Range` hand back a range of the wrong representation.
    /// nginx weakens it here for the same reason.
    private static func encoded(_ headers: HTTPFields) -> HTTPFields {
        var headers = headers
        headers[.contentEncoding] = ContentEncoding.gzip.rawValue
        headers[.contentLength] = nil
        if let tag = headers[.eTag], !tag.hasPrefix("W/") {
            headers[.eTag] = "W/\(tag)"
        }
        return headers
    }

    /// Whether gzip is both offered and not refused. Handles q-values, an
    /// explicit `gzip;q=0` (which is a refusal, not an offer) and `*`.
    static func negotiate(_ acceptEncoding: String?) -> ContentEncoding? {
        guard let acceptEncoding else { return nil }
        var wildcard: Double?
        for entry in acceptEncoding.split(separator: ",") {
            let parts = entry.split(separator: ";", maxSplits: 1)
            let coding = parts[0].trimmingCharacters(in: .whitespaces).lowercased()
            var quality = 1.0
            if parts.count == 2 {
                let parameter = parts[1].trimmingCharacters(in: .whitespaces).lowercased()
                if parameter.hasPrefix("q=") {
                    quality = Double(parameter.dropFirst(2)) ?? 1.0
                }
            }
            if coding == "gzip" { return quality > 0 ? .gzip : nil }
            if coding == "*" { wildcard = quality }
        }
        if let wildcard, wildcard > 0 { return .gzip }
        return nil
    }

    /// 1xx, 204 and 304 carry no body to compress.
    private static func statusAllowsBody(_ status: HTTPResponse.Status) -> Bool {
        status.kind != .informational && status != .noContent && status != .notModified
    }

    private static func vary(_ response: Response) -> Response {
        response.appendingVary(on: [.acceptEncoding])
    }
}
