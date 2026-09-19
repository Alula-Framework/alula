import FlightWeb
import Foundation
import Synchronization
import Testing

@testable import FlightTransport

@Suite("Inbound credit discipline")
struct InboundBackpressureTests {

    @Test("one credit is paid per frame taken, and none for the end")
    func creditPerTake() async {
        // The invariant the bound rests on. Pay a credit the frame was not
        // taken for and the window grows; skip one and the pump parks
        // forever holding a connection open.
        let (frames, framesContinuation) = AsyncStream<WebSocketFrame>.makeStream()
        let (credits, creditContinuation) = AsyncStream<Void>.makeStream()
        framesContinuation.yield(.text("one"))
        framesContinuation.yield(.text("two"))
        framesContinuation.finish()

        let handoff = InboundFrameHandoff(
            frames.makeAsyncIterator(), credits: creditContinuation)

        #expect(await handoff.next() != nil)
        #expect(await handoff.next() != nil)
        #expect(await handoff.next() == nil)  // stream finished
        creditContinuation.finish()

        var paid = 0
        for await _ in credits { paid += 1 }
        #expect(paid == 2, "expected one credit per delivered frame, got \(paid)")
    }

    @Test("credits are only paid as frames are taken, never up front")
    func creditsTrailTheConsumer() async {
        let (frames, framesContinuation) = AsyncStream<WebSocketFrame>.makeStream()
        let (credits, creditContinuation) = AsyncStream<Void>.makeStream()
        for text in ["a", "b", "c"] { framesContinuation.yield(.text(text)) }

        let handoff = InboundFrameHandoff(
            frames.makeAsyncIterator(), credits: creditContinuation)

        var creditIterator = credits.makeAsyncIterator()
        _ = await handoff.next()
        #expect(await creditIterator.next() != nil)

        // Two frames are sitting in the buffer, but no further credit has
        // been issued — which is what stops the pump fetching a fourth.
        let extra = Mutex(false)
        let waiting = Task {
            _ = await creditIterator.next()
            extra.withLock { $0 = true }
        }
        try? await Task.sleep(for: .milliseconds(50))
        #expect(extra.withLock { $0 } == false)
        waiting.cancel()
        framesContinuation.finish()
        creditContinuation.finish()
    }
}
