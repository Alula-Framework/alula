import AlulaWeb
import AlulaWebTesting
import Foundation
import HTTPTypes
import Testing

@Suite("Write preconditions")
struct WritePreconditionsTests {
    let current = EntityTag("v7")

    private func status(
        _ headers: HTTPFields, etag: EntityTag?, lastModified: Date? = nil, required: Bool = false
    ) -> Int {
        do {
            try RequestContext.mock(method: .put, path: "/doc", headers: headers)
                .checkWritePreconditions(etag: etag, lastModified: lastModified, required: required)
            return 200
        } catch let error as HTTPError {
            return error.httpStatus.code
        } catch {
            return 500
        }
    }

    @Test("If-Match passes on the current tag and refuses a stale one")
    func ifMatch() {
        #expect(status([.ifMatch: #""v7""#], etag: current) == 200)
        #expect(status([.ifMatch: #""v6", "v7""#], etag: current) == 200)
        #expect(status([.ifMatch: #""v6""#], etag: current) == 412)
    }

    @Test("If-Match compares strongly: a weak tag never matches")
    func strong() {
        #expect(status([.ifMatch: #"W/"v7""#], etag: current) == 412)
        #expect(status([.ifMatch: #""v7""#], etag: EntityTag("v7", weak: true)) == 412)
    }

    @Test("If-Match: * passes only when the resource exists")
    func star() {
        #expect(status([.ifMatch: "*"], etag: current) == 200)
        #expect(status([.ifMatch: "*"], etag: nil) == 412)
    }

    @Test("If-Unmodified-Since refuses a resource changed after it")
    func unmodifiedSince() {
        let modified = Date(timeIntervalSince1970: 1_800_000_000)
        let before = "Thu, 14 Jan 2027 07:59:59 GMT"
        let atOrAfter = "Fri, 15 Jan 2027 08:00:00 GMT"
        #expect(
            status([.ifUnmodifiedSince: atOrAfter], etag: current, lastModified: modified) == 200)
        #expect(status([.ifUnmodifiedSince: before], etag: current, lastModified: modified) == 412)
    }

    @Test("with required, a write without a precondition is a 428")
    func required() {
        #expect(status([:], etag: current, required: true) == 428)
        #expect(status([:], etag: current) == 200)
    }
}
