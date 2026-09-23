import AlulaWeb
import Foundation
import Synchronization
import Testing

@Suite("Inbound frames pull rather than buffer")
struct WebSocketFramesTests {

    @Test("nothing is read until the consumer asks for it")
    func nothingIsReadAhead() async {
        // The whole property, stated directly: an unbounded stream's producer
        // runs regardless of the consumer, and that is what grew memory.
        let reads = Mutex(0)
        let remaining = Mutex(3)
        let frames = WebSocketFrames {
            reads.withLock { $0 += 1 }
            return remaining.withLock { count -> WebSocketFrame? in
                guard count > 0 else { return nil }
                count -= 1
                return .text("frame")
            }
        }

        #expect(reads.withLock { $0 } == 0, "constructing it read from the socket")

        var iterator = frames.makeAsyncIterator()
        _ = await iterator.next()
        #expect(reads.withLock { $0 } == 1)
        _ = await iterator.next()
        #expect(reads.withLock { $0 } == 2)
    }

    @Test("it delivers every frame in order and stops at nil")
    func deliversInOrder() async {
        let pending = Mutex(["a", "b", "c"])
        let frames = WebSocketFrames {
            pending.withLock { queue -> WebSocketFrame? in
                guard !queue.isEmpty else { return nil }
                return .text(queue.removeFirst())
            }
        }
        var received: [String] = []
        for await frame in frames {
            if case .text(let text) = frame { received.append(text) }
        }
        #expect(received == ["a", "b", "c"])
    }

    @Test("a stream-backed sequence still works, for transports that have one")
    func streamCompatibility() async {
        let (stream, continuation) = AsyncStream<WebSocketFrame>.makeStream()
        continuation.yield(.text("one"))
        continuation.yield(.text("two"))
        continuation.finish()

        var received: [String] = []
        for await frame in WebSocketFrames(stream) {
            if case .text(let text) = frame { received.append(text) }
        }
        #expect(received == ["one", "two"])
    }

    @Test("a connection built from a stream keeps working")
    func connectionSourceCompatibility() async throws {
        // The pre-existing initializer: every in-memory harness uses it, and
        // it must not have become a compile error.
        let (stream, continuation) = AsyncStream<WebSocketFrame>.makeStream()
        continuation.yield(.text("hello"))
        continuation.finish()
        let sent = Mutex<[String]>([])
        let connection = WebSocketConnection(
            frames: stream,
            send: { frame in
                if case .text(let text) = frame { sent.withLock { $0.append(text) } }
            },
            close: { _, _ in })

        var received: [String] = []
        for await frame in connection.frames {
            if case .text(let text) = frame { received.append(text) }
        }
        try await connection.send("pong")
        #expect(received == ["hello"])
        #expect(sent.withLock { $0 } == ["pong"])
    }
}
