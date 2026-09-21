import FlightSessions
import Foundation
import HTTPTypes
import Logging

/// What the session middleware is composed with: the store, the settings,
/// the value coding, and the clock. One immutable reference shared by every
/// request, provided by ``FlightSessionsModule``.
///
/// Typed distinctly from `any SessionStore` on purpose: an adapter module
/// *provides* a store and this module *takes* it, and if this module also
/// provided the same type the composer would see two providers of one type
/// and stop (D27). Same reason `FlightCacheModule` provides a `CacheRuntime`
/// rather than the `Cache` it wraps.
public final class SessionRuntime: Sendable {
    public let store: any SessionStore
    public let settings: SessionSettings
    let coding: Session.Coding
    let now: @Sendable () -> Date

    /// - Parameters:
    ///   - store: Where sessions live.
    ///   - settings: Cookie attributes and the TTL.
    ///   - coding: How values are turned into bytes. Plain JSON by default;
    ///     it is not the wire's `WebCoders`, and on purpose — see
    ///     ``FlightSessionsModule/init(configuration:store:)``.
    ///   - now: The clock, injectable so expiry and renewal are testable.
    public init(
        store: any SessionStore,
        settings: SessionSettings,
        coding: Session.Coding = .json,
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.store = store
        self.settings = settings
        self.coding = coding
        self.now = now
    }
}

/// Loads the session the request's cookie names, hands it to everything
/// downstream as `context.session`, and persists what the handler did to it
/// once the handler has returned. ``FlightSessionsModule`` puts it in the
/// default lane.
///
/// No cookie, a cookie that does not parse, or one naming a session the
/// store no longer has: the request gets an empty session, and nothing is
/// stored unless it writes. That is what keeps a crawler from filling the
/// store, and it is why an expired session is indistinguishable from a
/// fresh visit — which is the right answer, since that is what it is.
///
/// A store that throws is a **503**, on the way in and on the way out. A
/// session that silently read empty would sign the user out without a word;
/// a save that silently dropped would lose a login after the handler
/// reported success. Refusing is honest, and the operator sees it.
///
/// What the handler did is committed whether or not it succeeded: the router
/// renders a handler's error into a response *inside* the chain, so this
/// layer sees a 500 rather than a throw, and it persists the session that
/// went with it. A handler that wants nothing kept on failure calls
/// `session.destroy()` on the way out, or does its writes last.
///
/// An upgrade response cannot carry `Set-Cookie`. A WebSocket route reads
/// its session at upgrade; writes made there are committed to the store but
/// a *new* session's cookie never reaches the client, so create the session
/// on an ordinary route first.
public struct Sessions: Middleware {
    private let runtime: SessionRuntime

    public init(runtime: SessionRuntime) {
        self.runtime = runtime
    }

    public func handle(_ context: RequestContext, next: Next) async throws -> Response {
        // Already loaded by a `Sessions` further out in this chain: pass
        // through. Idempotence is what lets two modules each put this layer
        // in a lane — `FlightSessionsModule` in the default lane for every
        // application, and `FlightSecurityModule` ahead of `Authentication`
        // in the lanes it owns — without a route that names both paying two
        // loads, or two commits racing over one record.
        if context.session != nil {
            return try await next(context)
        }
        let settings = runtime.settings
        let session = try await load(context)

        var downstream = context
        downstream.session = session
        let response = try await next(downstream)

        switch session.commit(now: runtime.now(), ttl: settings.ttl) {
        case .nothing:
            return response

        case .save(let id, let record, let replacing):
            do {
                try await runtime.store.save(id, try record.encoded(), ttl: settings.ttl)
                if let replacing {
                    try await runtime.store.delete(replacing)
                }
            } catch {
                context.logger.error(
                    "session store failed; refusing the request",
                    metadata: ["operation": "save", "reason": "\(error)"])
                throw SessionUnavailableError(operation: .save)
            }
            return response.settingCookie(cookie(for: id))

        case .delete(let id):
            do {
                try await runtime.store.delete(id)
            } catch {
                context.logger.error(
                    "session store failed; refusing the request",
                    metadata: ["operation": "delete", "reason": "\(error)"])
                throw SessionUnavailableError(operation: .delete)
            }
            return response.expiringCookie(
                settings.cookieName, path: settings.cookiePath, domain: settings.cookieDomain)
        }
    }

    private func load(_ context: RequestContext) async throws -> Session {
        guard let value = context.request.cookie(runtime.settings.cookieName),
            let id = SessionID(cookieValue: value)
        else {
            return Session(coding: runtime.coding)
        }
        let data: Data?
        do {
            data = try await runtime.store.load(id)
        } catch {
            context.logger.error(
                "session store failed; refusing the request",
                metadata: ["operation": "load", "reason": "\(error)"])
            throw SessionUnavailableError(operation: .load)
        }
        guard let data else {
            return Session(coding: runtime.coding)
        }
        do {
            return Session(
                id: id, record: try SessionRecord(decoding: data), coding: runtime.coding)
        } catch {
            // Bytes under a well-formed id that are not a record: a store
            // shared with something else, or a format this version no longer
            // reads. Not the client's doing, and not worth refusing them
            // for — but worth one line, because it will not fix itself.
            context.logger.warning(
                "stored session did not decode; starting a fresh one",
                metadata: ["session": "\(id)", "reason": "\(error)"])
            return Session(coding: runtime.coding)
        }
    }

    private func cookie(for id: SessionID) -> Cookie {
        let settings = runtime.settings
        return Cookie(
            name: settings.cookieName,
            value: id.cookieValue,
            path: settings.cookiePath,
            domain: settings.cookieDomain,
            maxAge: settings.ttl,
            isSecure: settings.cookieSecure,
            isHTTPOnly: true,
            sameSite: settings.cookieSameSite)
    }
}

/// A middleware that reads `context.session`, and therefore has to run after
/// ``Sessions`` in any lane that has one.
///
/// Conforming is what lets composition refuse a lane that lists the reader
/// first — at startup, naming the route and both layers — instead of the
/// reader seeing an empty session on every request and nothing saying why.
/// A lane with no `Sessions` in it at all is left alone: the reader then
/// sees `nil`, which is the documented "not configured" answer, and that is
/// its business to handle. `Authentication` in FlightSecurityCore conforms.
public protocol SessionReading: Middleware {}

/// The session store could not answer. Rendered as a bare 503; the reason
/// is in the log.
public struct SessionUnavailableError: Error, Sendable, Equatable, HTTPErrorRepresentable,
    CustomStringConvertible
{
    public let operation: SessionStoreError.Operation

    public init(operation: SessionStoreError.Operation) {
        self.operation = operation
    }

    public var httpStatus: HTTPResponse.Status { .serviceUnavailable }
    public var httpMessage: String { "Service Unavailable" }
    public var description: String { "session store unavailable during \(operation.rawValue)" }
}

/// `context.requireSession()` ran on a request no ``Sessions`` middleware
/// saw. A programming error — the module is not listed, or the route names
/// a lane without it — so it renders as an opaque 500 and says which in the
/// log.
public struct SessionNotConfiguredError: Error, Sendable, CustomStringConvertible {
    public init() {}

    public var description: String {
        """
        requireSession() was called, but no Sessions middleware ran for this request. List \
        FlightSessionsModule in the application's modules, and if the route names its own \
        lanes, include Sessions in one of them.
        """
    }
}

extension RequestContext {
    /// This request's session, or a thrown ``SessionNotConfiguredError`` when
    /// no ``Sessions`` middleware ran. Prefer this over unwrapping
    /// ``session`` in a handler: the failure names the fix.
    public func requireSession() throws -> Session {
        guard let session else { throw SessionNotConfiguredError() }
        return session
    }
}
