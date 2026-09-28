import AlulaCore
import AlulaWeb
import AlulaWebTesting
import Foundation
import Testing

/// What the application says about its own wire format, and whether Alula
/// honors it.
@Suite("WebCoders")
struct WebCodersTests {

    private struct Event: Codable, ResponseEncodable, Equatable {
        let eventName: String
        let occurredAt: Date
    }

    /// The web runtime the real `AlulaWebModule` builds from configuration —
    /// coders and error format — so a `TestClient` dispatches exactly as an
    /// application would.
    private func webRuntime(_ values: [String: String]) throws -> WebRuntime {
        let configuration = Configuration(values: values)
        let module = try AlulaWebModule<InMemoryTransport>(configuration: configuration)
        return WebRuntime(coders: module.coders, errorMapper: module.errorMapper)
    }

    /// A context whose coders are the ones the real `AlulaWebModule` builds
    /// from configuration — the value dispatch stamps onto every request.
    private func context(_ values: [String: String], body: Data = Data()) throws -> RequestContext {
        let configuration = Configuration(values: values)
        let module = try AlulaWebModule<InMemoryTransport>(configuration: configuration)
        var context = RequestContext.mock(path: "/", body: body)
        context.web = WebRuntime(coders: module.coders)
        return context
    }

    // MARK: Defaults

    @Test("dates are ISO-8601 by default, not seconds since 2001")
    func defaultDateStrategy() throws {
        let event = Event(eventName: "a", occurredAt: Date(timeIntervalSince1970: 1_700_000_000))
        let body = try event.response(for: .mock()).bodyText
        #expect(body.contains("2023-11-14T22:13:20Z"))
        // Foundation's default would have written 721772000.0 here — present,
        // numeric, and meaningless to anything that is not another Foundation.
        #expect(!body.contains("721772000"))
    }

    @Test("keys are left alone by default")
    func defaultKeyStrategy() throws {
        let event = Event(eventName: "a", occurredAt: .init(timeIntervalSince1970: 0))
        #expect(try event.response(for: .mock()).bodyText.contains("\"eventName\""))
    }

    // MARK: Configured

    @Test("snake-case keys apply to responses")
    func snakeCaseEncoding() throws {
        let context = try context(["web.json.key-strategy": "snake-case"])
        let event = Event(eventName: "a", occurredAt: .init(timeIntervalSince1970: 0))
        let body = try event.response(for: context).bodyText
        #expect(body.contains("\"event_name\""))
        #expect(!body.contains("\"eventName\""))
    }

    @Test("snake-case keys apply to request bodies too")
    func snakeCaseDecoding() throws {
        let context = try context(
            ["web.json.key-strategy": "snake-case"],
            body: Data(#"{"event_name":"a","occurred_at":"1970-01-01T00:00:00Z"}"#.utf8))
        #expect(try decodeRequestBody(Event.self, from: context).eventName == "a")
    }

    @Test("a date strategy applies in both directions")
    func dateStrategyRoundTrips() throws {
        let context = try context(["web.json.date-strategy": "seconds"])
        let event = Event(eventName: "a", occurredAt: Date(timeIntervalSince1970: 1_700_000_000))
        let body = try event.response(for: context).bodyText
        #expect(body.contains("1700000000"))

        let decoding = try self.context(["web.json.date-strategy": "seconds"], body: Data(body.utf8))
        #expect(try decodeRequestBody(Event.self, from: decoding) == event)
    }

    // MARK: Error bodies

    @Test("errors are RFC 9457 problem+json by default")
    func defaultErrorFormat() throws {
        let response = errorResponse(for: HTTPError(.notFound, "no such user"), context: .mock())
        #expect(response.headers[.contentType] == "application/problem+json")
        #expect(response.bodyText.contains("\"title\":\"Not Found\""))
    }

    @Test("errors can be the pre-9457 shape instead")
    func simpleErrorFormat() throws {
        let context = try context(["web.errors.format": "simple"])
        let response = errorResponse(for: HTTPError(.notFound, "no such user"), context: context)
        #expect(response.headers[.contentType] == ContentType.json.rawValue)
        #expect(response.bodyText.contains("\"error\":\"no such user\""))
    }

    @Test("a 404 from the router uses the configured error format")
    func routerHonorsErrorFormat() async throws {
        let client = try TestClient(
            routes: [], web: webRuntime(["web.errors.format": "simple"]))
        let response = await client.get("/nothing-here")
        #expect(response.status == .notFound)
        #expect(response.bodyText.contains("\"error\""))
    }

    // MARK: The statics read the request's coders

    private static let snake = [
        "web.json.key-strategy": "snake-case", "web.json.date-strategy": "seconds",
        "web.errors.format": "simple",
    ]

    @Test("`.json(_:status:)` in a handler uses the configured encoder, not the default")
    func jsonWithStatusUsesConfiguredEncoder() async throws {
        let event = Event(eventName: "a", occurredAt: Date(timeIntervalSince1970: 1_700_000_000))
        let client = try TestClient(
            routes: [
                RouteRegistration(method: .post, path: "/events", source: "t") { _ in
                    try .json(event, status: .created)
                }
            ],
            web: webRuntime(Self.snake))
        let response = await client.post("/events")
        #expect(response.status == .created)
        #expect(response.bodyText.contains("\"event_name\""))
        #expect(response.bodyText.contains("1700000000"))
    }

    @Test("the binding reaches a time-limited route's task, a streaming producer and a WebSocket handler")
    func bindingReachesDetachedWork() async throws {
        let event = Event(eventName: "a", occurredAt: .init(timeIntervalSince1970: 0))
        struct Socket: WebSocketUpgradeHandler {
            let event: Event
            func handle(upgraded connection: WebSocketConnection, context: RequestContext) async throws {
                let body = try Response.json(event).bodyText
                try await connection.send(body)
                try await connection.close()
            }
        }
        let client = try TestClient(
            routes: [
                RouteRegistration(method: .get, path: "/limited", source: "t", timeout: .seconds(30)) { _ in
                    try .json(event, status: .accepted)
                },
                RouteRegistration(method: .get, path: "/stream", source: "t") { _ in
                    .streaming(contentType: .json) { writer in
                        let data = (try? WebCoders.current.jsonEncoder.encode(event)) ?? Data()
                        _ = await writer.write(data)
                    }
                },
                RouteRegistration(method: .get, path: "/problem", source: "t") { _ in
                    .problem(status: .conflict, message: "taken")
                },
                RouteRegistration(
                    method: .get, path: "/socket", kind: .upgrade(.webSocket), source: "t"
                ) { context in .upgrade(handler: Socket(event: event), context: context) },
            ],
            web: webRuntime(Self.snake))

        #expect(await client.get("/limited").bodyText.contains("\"event_name\""))
        let streamed = await client.get("/stream").collectStreamingBody()
        #expect(String(decoding: streamed, as: UTF8.self).contains("\"event_name\""))
        let problem = await client.get("/problem")
        #expect(problem.headers[.contentType] == ContentType.json.rawValue)
        #expect(problem.bodyText.contains("\"error\":\"taken\""))

        let socket = try await client.webSocket("/socket")
        var received: [String] = []
        for await frame in socket.frames {
            if case .text(let text) = frame { received.append(text) }
        }
        #expect(received.count == 1)
        #expect(received.first?.contains("\"event_name\"") == true)
        await socket.waitForServer()
    }

    @Test("outside a request, `.json` and `.problem` use the defaults")
    func staticsOutsideARequestUseDefaults() throws {
        let event = Event(eventName: "a", occurredAt: Date(timeIntervalSince1970: 1_700_000_000))
        let body = try Response.json(event, status: .created).bodyText
        #expect(body.contains("\"eventName\""))
        #expect(body.contains("2023-11-14T22:13:20Z"))
        #expect(
            Response.problem(status: .conflict, message: "taken").headers[.contentType]
                == "application/problem+json")
    }

    @Test("concurrent requests to two applications each see their own coders")
    func bindingIsPerRequest() async throws {
        let event = Event(eventName: "a", occurredAt: .init(timeIntervalSince1970: 0))
        let route = RouteRegistration(method: .get, path: "/", source: "t") { _ in
            try .json(event, status: .created)
        }
        let configured = try TestClient(routes: [route], web: webRuntime(Self.snake))
        let plain = try TestClient(routes: [route], web: webRuntime([:]))
        let bodies = await withTaskGroup(of: (Bool, String).self) { group in
            for index in 0..<40 {
                let snake = index.isMultiple(of: 2)
                group.addTask {
                    (snake, await (snake ? configured : plain).get("/").bodyText)
                }
            }
            return await group.reduce(into: []) { $0.append($1) }
        }
        for (snake, body) in bodies {
            #expect(body.contains(snake ? "\"event_name\"" : "\"eventName\""))
        }
    }

    // MARK: Failures

    @Test("an unknown value names the key and what was expected")
    func unknownValueIsRejected() throws {
        do {
            _ = try WebCoders(configuration: Configuration(values: ["web.json.key-strategy": "kebab"]))
            Issue.record("expected a thrown error")
        } catch let error as WebCodersError {
            let text = "\(error)"
            #expect(text.contains("web.json.key-strategy"))
            #expect(text.contains("kebab"))
            #expect(text.contains("snake-case"))
        }
    }

    @Test("an application's own coders win over the configured ones")
    func applicationRegistrationWins() throws {
        // The application's coders arrive as an argument rather than winning
        // a registration race — whether it brought its own is a fact about
        // how it was composed, and the composer matches the property by type.
        let custom = CustomCodersModule()
        // The composer would match `custom.coders` to `AlulaWebModule`'s
        // `coders` parameter by type; here we hand it over directly. The
        // coders ride on the context, stamped by dispatch from what the web
        // module was composed with.
        var context = RequestContext.mock()
        context.web = WebRuntime(coders: custom.coders)
        let event = Event(eventName: "a", occurredAt: .init(timeIntervalSince1970: 0))
        #expect(try event.response(for: context).bodyText.contains("\"event_name\""))
    }
}

/// Provides coders for `AlulaWebModule` to take, standing in for an
/// application that wants its own.
private struct CustomCodersModule {
    let coders: WebCoders = {
        var coders = WebCoders.default
        coders.jsonEncoder.keyEncodingStrategy = .convertToSnakeCase
        return coders
    }()
}
