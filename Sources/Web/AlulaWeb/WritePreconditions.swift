import Foundation
import HTTPTypes

extension RequestContext {
    /// Refuses a write made against a version of the resource that is no
    /// longer current: the lost-update check for PUT, PATCH and DELETE.
    ///
    /// ```swift
    /// @PutRoute("/documents/:id")
    /// func replace(_ context: RequestContext, id: UUID, body: DocumentBody) async throws -> Response {
    ///     guard let current = try await documents.find(id) else { throw HTTPError(.notFound) }
    ///     try context.checkWritePreconditions(
    ///         etag: EntityTag(String(current.version)), required: true)
    ///     let saved = try await documents.replace(id, with: body, expecting: current.version)
    ///     return try .json(saved).settingHeader(.eTag, EntityTag(String(saved.version)).headerValue)
    /// }
    /// ```
    ///
    /// A client sends back the `ETag` it read in `If-Match`. If someone else
    /// has written since, the tags differ and this throws `412 Precondition
    /// Failed`, where the write would otherwise have silently overwritten
    /// theirs. RFC 9110 §13.1.1 and §13.2.2:
    ///
    /// - `If-Match` compares strongly: a weak tag, on either side, never
    ///   matches. `If-Match: *` passes whenever the resource exists.
    /// - `If-Unmodified-Since` is only consulted without `If-Match`, and only
    ///   when `lastModified` is given.
    /// - With `required`, a request carrying neither is refused with `428
    ///   Precondition Required`, so a client cannot skip the check by
    ///   leaving the header off.
    ///
    /// The check reads the resource before writing it, so two writes can
    /// still race between the two. Make the write itself conditional on the
    /// version (`UPDATE … WHERE version = $1`) to close that window; this is
    /// the part that tells the client.
    ///
    /// - Parameters:
    ///   - etag: The resource's current entity tag, or nil when it does
    ///     not exist.
    ///   - lastModified: When it last changed, for `If-Unmodified-Since`.
    ///   - required: Whether a request without a precondition is refused.
    /// - Throws: `HTTPError` with `412` or `428`.
    public func checkWritePreconditions(
        etag: EntityTag?, lastModified: Date? = nil, required: Bool = false
    ) throws {
        if let raw = request.headers[values: .ifMatch].nonEmptyJoined {
            guard let condition = IfNoneMatch(raw) else {
                throw HTTPError(.preconditionFailed, "If-Match is not a valid entity-tag list")
            }
            let passes =
                condition.star
                ? etag != nil
                : etag.map { current in condition.tags.contains { $0.stronglyMatches(current) } }
                    ?? false
            guard passes else {
                throw HTTPError(
                    .preconditionFailed, "The resource has changed since it was read")
            }
            return
        }
        if let raw = request.headers[.ifUnmodifiedSince] {
            if let lastModified, let since = HTTPDate.parse(raw),
                lastModified.timeIntervalSince1970.rounded(.down) > since.timeIntervalSince1970
            {
                throw HTTPError(
                    .preconditionFailed, "The resource has changed since it was read")
            }
            return
        }
        if required {
            throw HTTPError(
                HTTPResponse.Status(code: 428, reasonPhrase: "Precondition Required"),
                "Send If-Match with the ETag this change is based on")
        }
    }
}

extension Array where Element == String {
    /// Every value of a repeated header as one list, or nil when absent.
    fileprivate var nonEmptyJoined: String? {
        isEmpty ? nil : joined(separator: ", ")
    }
}
