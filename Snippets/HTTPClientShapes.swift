// Every shape Docs/http-client.md claims, compiled.
//
// A doc example that does not compile costs a reader the time to find out.
// This builds as part of `swift build`, so a rename that invalidates the
// prose breaks the build.

import AlulaCore
import AlulaHTTPClient
import AlulaHTTPClientTesting
import Foundation
import HTTPTypes

// snippet.hide
struct Forecast: Codable, Sendable { let high: Int }
struct Invoice: Codable, Sendable { let id: String }
let invoicesURL = URL(string: "https://api.example.com/invoices")!
// snippet.show

// MARK: Using it

@Service struct Weather {
    @Inject var http: OutboundHTTPClient

    func forecast(for city: String) async throws -> Forecast {
        try await http.get(URL(string: "https://api.example.com/forecast?city=\(city)")!)
            .decode(Forecast.self)
    }
}

func sendShapes(http: OutboundHTTPClient) async throws {
    // Method, URL, headers, body, and an optional per-request timeout.
    let response = try await http.send(
        OutboundRequest(
            method: .put, url: invoicesURL, headers: [.contentType: "application/json"],
            body: Data("{}".utf8), timeout: .seconds(5)))
    _ = response.status

    // A POST is retried only with an Idempotency-Key.
    var headers = HTTPFields()
    headers[HTTPField.Name("Idempotency-Key")!] = UUID().uuidString
    _ = try await http.post(invoicesURL, json: Invoice(id: "1"), headers: headers)

    // `decode` demands a 2xx; anything else is `unexpectedStatus`.
    do {
        _ = try response.decode(Invoice.self)
    } catch OutboundHTTPError.unexpectedStatus(let status, let bodyPrefix) {
        _ = (status, bodyPrefix)
    }
}

// The `http-client.*` keys, as the module reads them.
func policyShapes(configuration: Configuration) throws {
    _ = try AlulaHTTPClientModule(configuration: configuration).httpClient
    _ = OutboundHTTPPolicy(timeout: .seconds(30), maxAttempts: 3, maxResponseBytes: 10_485_760)
}

// MARK: Calling as a service account

@Service struct Invoices {
    @Inject var core: AuthorizedHTTPClient

    func list() async throws -> [Invoice] {
        try await core.send(OutboundRequest(url: invoicesURL)).decode([Invoice].self)
    }
}

func clientCredentialsShapes(configuration: Configuration, http: OutboundHTTPClient) throws {
    _ = try AlulaClientCredentialsModule(configuration: configuration, httpClient: http)
    let settings = ClientCredentialsSettings(
        endpoint: .issuer(URL(string: "https://id.example.com/realms/main")!),
        clientID: "billing-worker", clientSecret: "secret", scope: "invoices:write",
        audience: "https://api.example.com", clientAuthentication: .basic)
    let tokens = ClientCredentialsTokenSource(settings: settings, http: http)
    _ = AuthorizedHTTPClient(http: http, tokens: tokens)
}

// MARK: Testing

func testingShapes() async throws {
    let stub = StubHTTPTransport(responses: [
        .init(status: .serviceUnavailable),
        .init(status: .ok, body: Data(#"{"high":21}"#.utf8)),
    ])
    let weather = Weather(http: OutboundHTTPClient(transport: stub))
    let forecast = try await weather.forecast(for: "Oslo")
    precondition(forecast.high == 21)
    precondition(stub.requests.count == 2)  // the retry is visible
}
