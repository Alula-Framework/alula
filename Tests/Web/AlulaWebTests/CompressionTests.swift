import CAlulaZlib
import AlulaCore
@testable import AlulaWeb
import AlulaWebTesting
import Foundation
import HTTPTypes
import Logging
import Testing

/// Reads back what the middleware produced, with zlib rather than with our
/// own encoder — a round trip through the same code that wrote it would pass
/// just as happily on a stream no client can read.
private func gunzip(_ data: Data) throws -> Data {
    var stream = z_stream()
    let status = inflateInit2_(
        &stream, 15 + 16, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size))
    try #require(status == Z_OK)
    defer { inflateEnd(&stream) }

    var input = data
    var output = Data()
    var buffer = [UInt8](repeating: 0, count: 64 * 1024)
    try input.withUnsafeMutableBytes { raw in
        stream.next_in = raw.bindMemory(to: UInt8.self).baseAddress
        stream.avail_in = uInt(raw.count)
        while true {
            let produced: Int = buffer.withUnsafeMutableBufferPointer { out in
                stream.next_out = out.baseAddress
                stream.avail_out = uInt(out.count)
                let result = inflate(&stream, Z_NO_FLUSH)
                guard result == Z_OK || result == Z_STREAM_END || result == Z_BUF_ERROR
                else { return -1 }
                return 64 * 1024 - Int(stream.avail_out)
            }
            try #require(produced >= 0, "zlib rejected the stream")
            guard produced > 0 else { break }
            output.append(contentsOf: buffer[0..<produced])
        }
    }
    return output
}

/// Big enough to clear the floor and to compress well.
private let bigJSON: String = {
    let row = #"{"id":%d,"name":"widget","state":"active","tags":["a","b","c"]}"#
    return "[" + (0..<200).map { String(format: row, $0) }.joined(separator: ",") + "]"
}()

@Controller("/c")
private struct CompressionTestController {
    @GetRoute("/json")
    func json(_ context: RequestContext) async throws -> Response {
        .text(bigJSON, status: .ok).settingHeader(.contentType, "application/json")
    }

    @GetRoute("/small")
    func small(_ context: RequestContext) async throws -> Response {
        .text("tiny").settingHeader(.contentType, "application/json")
    }

    @GetRoute("/png")
    func png(_ context: RequestContext) async throws -> Response {
        .data(Data(repeating: 7, count: 40_000), contentType: ContentType("image/png"))
    }

    /// Stands in for what StaticAssets serves from a `.br` variant.
    @GetRoute("/prebuilt")
    func prebuilt(_ context: RequestContext) async throws -> Response {
        Response.text(bigJSON)
            .settingHeader(.contentType, "application/json")
            .settingHeader(.contentEncoding, "br")
    }

    @GetRoute("/tagged")
    func tagged(_ context: RequestContext) async throws -> Response {
        Response.text(bigJSON)
            .settingHeader(.contentType, "application/json")
            .settingHeader(.eTag, "\"v1\"")
    }

    @GetRoute("/empty")
    func empty(_ context: RequestContext) async throws -> Response { .noContent }
}

@Suite("Response compression")
struct CompressionTests {

    private func client() throws -> TestClient {
        try TestClient(
            routes: CompressionTestController.alulaRoutes { _ in CompressionTestController() },
            middleware: MiddlewareRegistration.lane(.default, [ResponseCompression()]))
    }

    // MARK: The thing that matters

    @Test("a compressed body is one zlib reads back byte for byte")
    func roundTrips() async throws {
        let response = await (try client()).get(
            "/c/json", headers: [.acceptEncoding: "gzip"])
        #expect(response.status == .ok)
        #expect(response.headers[.contentEncoding] == "gzip")

        let body = try #require(response.bodyData)
        // gzip's magic number, so a body that is merely *shorter* cannot pass.
        #expect(body.prefix(2) == Data([0x1f, 0x8b]))
        #expect(try gunzip(body) == Data(bigJSON.utf8))
        #expect(body.count < bigJSON.utf8.count)
    }

    @Test("the length header is left for the transport to recompute")
    func contentLengthIsCleared() async throws {
        let response = await (try client()).get("/c/json", headers: [.acceptEncoding: "gzip"])
        // A stale uncompressed length here truncates every response.
        #expect(response.headers[.contentLength] == nil)
    }

    @Test("Vary is set whether or not anything was compressed")
    func varyIsAlwaysSet() async throws {
        let compressed = await (try client()).get("/c/json", headers: [.acceptEncoding: "gzip"])
        let plain = await (try client()).get("/c/json")
        // The uncompressed copy is the one that matters: without Vary a cache
        // hands it to the next client, gzip-capable or not — or worse, hands
        // the gzip to one that is not.
        #expect(compressed.headers[.vary]?.lowercased().contains("accept-encoding") == true)
        #expect(plain.headers[.vary]?.lowercased().contains("accept-encoding") == true)
    }

    // MARK: What it declines

    @Test("no Accept-Encoding means no compression")
    func withoutAcceptEncoding() async throws {
        let response = await (try client()).get("/c/json")
        #expect(response.headers[.contentEncoding] == nil)
        #expect(response.bodyData == Data(bigJSON.utf8))
    }

    @Test("a body under the floor is left alone")
    func belowTheFloor() async throws {
        let response = await (try client()).get("/c/small", headers: [.acceptEncoding: "gzip"])
        #expect(response.headers[.contentEncoding] == nil)
        #expect(response.bodyText == "tiny")
    }

    @Test("an already-compressed media type is left alone")
    func incompressibleType() async throws {
        let response = await (try client()).get("/c/png", headers: [.acceptEncoding: "gzip"])
        #expect(response.headers[.contentEncoding] == nil)
        #expect(response.bodyData?.count == 40_000)
    }

    @Test("a pre-compressed response is never compressed twice")
    func alreadyEncoded() async throws {
        let response = await (try client()).get("/c/prebuilt", headers: [.acceptEncoding: "gzip"])
        // gzip-wrapped brotli is what the guard exists to prevent.
        #expect(response.headers[.contentEncoding] == "br")
    }

    @Test("a bodiless status is left alone")
    func noContent() async throws {
        let response = await (try client()).get("/c/empty", headers: [.acceptEncoding: "gzip"])
        #expect(response.status == .noContent)
        #expect(response.headers[.contentEncoding] == nil)
    }

    @Test("a strong ETag is weakened, because the bytes changed")
    func etagIsWeakened() async throws {
        let compressed = await (try client()).get("/c/tagged", headers: [.acceptEncoding: "gzip"])
        let plain = await (try client()).get("/c/tagged")
        #expect(compressed.headers[.eTag] == "W/\"v1\"")
        #expect(plain.headers[.eTag] == "\"v1\"")
    }

    // MARK: Negotiation

    @Test("q-values decide, and q=0 is a refusal rather than an offer")
    func negotiation() {
        // An entry of just ";" split to nothing and was indexed: a trap from
        // any request through the middleware.
        #expect(ResponseCompression.negotiate("br, ;") == nil)
        #expect(ResponseCompression.negotiate(";") == nil)
        #expect(ResponseCompression.negotiate(";, gzip") == .gzip)
        #expect(ResponseCompression.negotiate("gzip") == .gzip)
        #expect(ResponseCompression.negotiate("gzip, deflate, br") == .gzip)
        #expect(ResponseCompression.negotiate("gzip;q=0.8") == .gzip)
        #expect(ResponseCompression.negotiate("*") == .gzip)
        #expect(ResponseCompression.negotiate(nil) == nil)
        #expect(ResponseCompression.negotiate("br") == nil)
        // The refusals. `gzip;q=0` says "not gzip" and is easy to read as
        // "gzip mentioned, therefore gzip".
        #expect(ResponseCompression.negotiate("gzip;q=0") == nil)
        #expect(ResponseCompression.negotiate("*;q=0") == nil)
        #expect(ResponseCompression.negotiate("br, gzip;q=0") == nil)
    }

    // MARK: Streaming

    @Test("a stream is flushed per chunk and still inflates whole")
    func streamingStaysLive() async throws {
        // Driven directly: the claim is about *when* bytes leave, which a
        // collected response cannot show.
        let events = ["one", "two", "three"]
        let source = AsyncStream<Data> { continuation in
            for event in events { continuation.yield(Data("data: \(event)\n\n".utf8)) }
            continuation.finish()
        }
        let upstream = Response.streaming(
            status: .ok,
            headers: [.contentType: "text/event-stream"],
            body: source)

        let context = RequestContext(
            request: Request(
                method: .get, path: "/events", headers: [.acceptEncoding: "gzip"]),
            logger: Logger(label: "test"))
        let response = try await ResponseCompression().handle(context) { _ in upstream }

        guard case .streaming(_, let headers, let body) = response else {
            Issue.record("expected a streaming response")
            return
        }
        #expect(headers[.contentEncoding] == "gzip")

        var chunks: [Data] = []
        for await chunk in body { chunks.append(chunk) }

        // More than one chunk carried bytes before the stream ended: that is
        // the difference between server-sent events and a single lump
        // delivered when the connection closes.
        #expect(chunks.count > 1, "the body was buffered rather than flushed")
        let whole = chunks.reduce(into: Data()) { $0 += $1 }
        #expect(try gunzip(whole) == Data(events.map { "data: \($0)\n\n" }.joined().utf8))
    }
}
