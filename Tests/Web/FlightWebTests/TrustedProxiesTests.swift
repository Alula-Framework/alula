import FlightCore
import Foundation
import HTTPTypes
import Logging
import Testing

@testable import FlightWeb

@Suite("TrustedProxies")
struct TrustedProxiesTests {

    private func request(
        remoteAddress: String? = "198.51.100.1", forwardedFor: String? = nil
    ) -> Request {
        var headers: HTTPFields = [:]
        if let forwardedFor { headers[.xForwardedFor] = forwardedFor }
        return Request(
            path: "/", headers: headers,
            remoteAddress: remoteAddress.map { PeerAddress(host: $0, port: 54321) })
    }

    // MARK: The default

    @Test("with nothing configured, clientAddress is always the raw peer")
    func defaultIsAlwaysTheRawPeer() {
        let proxies = TrustedProxies.none
        #expect(
            proxies.clientAddress(for: request())
                == PeerAddress(host: "198.51.100.1", port: 54321))
    }

    @Test("with nothing configured, a spoofed X-Forwarded-For is never even read")
    func defaultIgnoresXFFEntirely() {
        // The property that matters most: a caller with no proxy in front
        // cannot become "trusted" just by claiming to be one.
        let proxies = TrustedProxies.none
        let spoofed = request(forwardedFor: "1.2.3.4")
        #expect(proxies.clientAddress(for: spoofed)?.host == "198.51.100.1")
    }

    @Test("with no real peer at all, clientAddress is nil")
    func noRemoteAddressIsNil() {
        #expect(TrustedProxies.none.clientAddress(for: request(remoteAddress: nil)) == nil)
    }

    // MARK: An untrusted peer, even with a configured range

    @Test("a peer outside the trusted range is used as-is; its X-Forwarded-For is ignored")
    func untrustedPeerIgnoresXFF() throws {
        let proxies = try TrustedProxies(cidrs: ["10.0.0.0/8"])
        let outside = request(remoteAddress: "203.0.113.9", forwardedFor: "1.2.3.4")
        #expect(proxies.clientAddress(for: outside)?.host == "203.0.113.9")
    }

    // MARK: A trusted peer

    @Test("a trusted peer with no header at all falls back to its own address")
    func trustedPeerNoHeader() throws {
        let proxies = try TrustedProxies(cidrs: ["10.0.0.0/8"])
        let request = request(remoteAddress: "10.0.0.5")
        #expect(proxies.clientAddress(for: request)?.host == "10.0.0.5")
    }

    @Test("a trusted peer's header names the client")
    func trustedPeerSingleHop() throws {
        let proxies = try TrustedProxies(cidrs: ["10.0.0.0/8"])
        let request = request(remoteAddress: "10.0.0.5", forwardedFor: "203.0.113.9")
        #expect(proxies.clientAddress(for: request)?.host == "203.0.113.9")
    }

    @Test("a chain of trusted hops is walked back to the first untrusted entry")
    func multiHopTrustedChain() throws {
        // client -> proxyA (10.0.0.1) -> proxyB (10.0.0.2) -> us.
        // proxyA appended the client; proxyB appended proxyA.
        let proxies = try TrustedProxies(cidrs: ["10.0.0.0/8"])
        let request = request(
            remoteAddress: "10.0.0.2", forwardedFor: "203.0.113.9, 10.0.0.1")
        #expect(proxies.clientAddress(for: request)?.host == "203.0.113.9")
    }

    @Test("entries left of the trust boundary are never used, however many there are")
    func attackerPrependedEntriesAreIgnored() throws {
        // A client that talks to a trusted proxy can set X-Forwarded-For to
        // anything before it gets there. The proxy appends the client's
        // real address to the *end*; whatever the client put in the header
        // itself lands to the *left* of that and must never be trusted.
        let proxies = try TrustedProxies(cidrs: ["10.0.0.0/8"])
        let request = request(
            remoteAddress: "10.0.0.5",
            forwardedFor: "1.1.1.1, 2.2.2.2, 3.3.3.3, 203.0.113.9")
        #expect(proxies.clientAddress(for: request)?.host == "203.0.113.9")
    }

    @Test(
        "a header entirely composed of trusted-looking addresses resolves to nil rather than guessing"
    )
    func fullyTrustedChainWithNoClientIsNil() throws {
        let proxies = try TrustedProxies(cidrs: ["10.0.0.0/8"])
        let request = request(remoteAddress: "10.0.0.2", forwardedFor: "10.0.0.1")
        #expect(proxies.clientAddress(for: request) == nil)
    }

    @Test("an unparseable entry stops the walk with nil rather than being treated as the client")
    func unparseableEntryStopsWithNil() throws {
        let proxies = try TrustedProxies(cidrs: ["10.0.0.0/8"])
        let request = request(remoteAddress: "10.0.0.5", forwardedFor: "not-an-address")
        #expect(proxies.clientAddress(for: request) == nil)
    }

    @Test("whitespace around entries and an empty header are tolerated")
    func whitespaceAndEmptyEntries() throws {
        let proxies = try TrustedProxies(cidrs: ["10.0.0.0/8"])
        let padded = request(
            remoteAddress: "10.0.0.2", forwardedFor: " 203.0.113.9 ,  10.0.0.1  ")
        #expect(proxies.clientAddress(for: padded)?.host == "203.0.113.9")

        let empty = request(remoteAddress: "10.0.0.5", forwardedFor: "")
        #expect(proxies.clientAddress(for: empty)?.host == "10.0.0.5")
    }

    // MARK: Configuration

    @Test("cidrs: parses each entry, throwing on the first bad one, naming it")
    func cidrsParsing() throws {
        let proxies = try TrustedProxies(cidrs: ["10.0.0.0/8", "172.16.0.0/12"])
        #expect(proxies.isTrusted(PeerAddress(host: "10.1.2.3")))
        #expect(proxies.isTrusted(PeerAddress(host: "172.16.5.5")))
        #expect(!proxies.isTrusted(PeerAddress(host: "8.8.8.8")))

        #expect(throws: TrustedProxiesError.invalidRange("not-a-cidr")) {
            try TrustedProxies(cidrs: ["10.0.0.0/8", "not-a-cidr"])
        }
    }

    @Test("configuration reads web.trusted-proxies as a comma-separated list")
    func configurationReading() throws {
        let configured = try TrustedProxies(
            configuration: Configuration(values: [
                "web.trusted-proxies": "10.0.0.0/8, 172.16.0.0/12"
            ]))
        #expect(configured.isTrusted(PeerAddress(host: "10.1.2.3")))
        #expect(configured.isTrusted(PeerAddress(host: "172.16.5.5")))
        #expect(!configured.isTrusted(PeerAddress(host: "8.8.8.8")))
    }

    @Test("absent configuration is .none")
    func absentConfigurationIsNone() throws {
        #expect(try TrustedProxies(configuration: Configuration()) == .none)
    }

    @Test("a bad entry in configuration fails composition, naming it")
    func badConfigurationEntry() {
        #expect(throws: TrustedProxiesError.invalidRange("nope")) {
            try TrustedProxies(
                configuration: Configuration(values: ["web.trusted-proxies": "nope"]))
        }
    }

    @Test("the header names parse; the force-unwraps in the extension are safe")
    func headerNamesAreValid() {
        #expect(HTTPField.Name("x-forwarded-for") != nil)
        #expect(HTTPField.Name("forwarded") != nil)
        #expect(HTTPField.Name("x-csrf-token") != nil)
    }
}

@Suite("RequestContext.clientAddress")
struct ClientAddressTests {

    @Test("reads through WebRuntime's trustedProxies")
    func readsThroughWebRuntime() throws {
        let proxies = try TrustedProxies(cidrs: ["10.0.0.0/8"])
        let context = RequestContext(
            request: Request(
                path: "/", headers: [.xForwardedFor: "203.0.113.9"],
                remoteAddress: PeerAddress(host: "10.0.0.5")),
            logger: Logger(label: "test"),
            web: WebRuntime(trustedProxies: proxies))
        #expect(context.clientAddress?.host == "203.0.113.9")
    }

    @Test(
        "RequestContext.mock's remoteAddress is what clientAddress returns with no proxy configured"
    )
    func mockRemoteAddress() {
        let context = RequestContext.mock(remoteAddress: PeerAddress(host: "203.0.113.9"))
        #expect(context.clientAddress?.host == "203.0.113.9")
        #expect(context.request.remoteAddress?.host == "203.0.113.9")
    }
}
