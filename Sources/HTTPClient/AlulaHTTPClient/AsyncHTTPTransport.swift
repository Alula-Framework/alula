import AlulaCore
import AsyncHTTPClient
import Foundation
import HTTPTypes
import NIOCore
import NIOFoundationCompat
import NIOHTTP1

/// The production transport: AsyncHTTPClient's process-wide shared client,
/// which needs no lifecycle of its own.
public struct AsyncHTTPTransport: OutboundHTTPTransport {
    public init() {}

    public func send(_ request: OutboundRequest, timeout: Duration, maxResponseBytes: Int)
        async throws -> OutboundResponse
    {
        var clientRequest = HTTPClientRequest(url: request.url.absoluteString)
        clientRequest.method = HTTPMethod(rawValue: request.method.rawValue)
        for field in request.headers {
            clientRequest.headers.add(name: field.name.rawName, value: field.value)
        }
        if let body = request.body {
            clientRequest.body = .bytes(ByteBuffer(data: body))
        }
        let response: HTTPClientResponse
        do {
            response = try await HTTPClient.shared.execute(clientRequest, timeout: TimeAmount(timeout))
        } catch let error as HTTPClientError where error == .deadlineExceeded || error == .readTimeout
            || error == .connectTimeout
        {
            throw OutboundHTTPError.timedOut(timeout)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw OutboundHTTPError.transport(String(describing: error))
        }
        let body: ByteBuffer
        do {
            body = try await response.body.collect(upTo: maxResponseBytes)
        } catch is NIOTooManyBytesError {
            throw OutboundHTTPError.responseTooLarge(limit: maxResponseBytes)
        } catch let error as HTTPClientError where error == .deadlineExceeded {
            throw OutboundHTTPError.timedOut(timeout)
        } catch {
            throw OutboundHTTPError.transport(String(describing: error))
        }
        var headers = HTTPFields()
        for (name, value) in response.headers {
            if let fieldName = HTTPField.Name(name) { headers.append(HTTPField(name: fieldName, value: value)) }
        }
        return OutboundResponse(
            status: HTTPResponse.Status(code: Int(response.status.code)), headers: headers,
            body: Data(buffer: body))
    }
}

/// Provides an ``OutboundHTTPClient`` configured from `http-client.*`:
///
/// ```yaml
/// http-client:
///   timeout-seconds: 30
///   max-attempts: 3
///   max-response-bytes: 10485760
/// ```
public struct AlulaHTTPClientModule: AlulaModule {
    public let httpClient: OutboundHTTPClient

    public init(configuration: Configuration) throws {
        self.httpClient = OutboundHTTPClient(
            transport: AsyncHTTPTransport(), policy: try OutboundHTTPPolicy(configuration: configuration))
    }

    public init() {
        preconditionFailure(
            "AlulaHTTPClientModule takes its configuration in init(configuration:), so it cannot be "
                + "instantiated from its type. Pass `composedBy: alulaComposeModules` to Alula.run.")
    }
}
