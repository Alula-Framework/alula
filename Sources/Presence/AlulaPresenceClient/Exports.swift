/// Re-exported so `import AlulaPresenceClient` brings the wire vocabulary —
/// `PresenceEntry`, `PresenceMeta` and the presence events — without a second
/// import. AlulaPresenceProtocol is not a product of its own: a client reaches
/// it here, a server through AlulaPresence.
@_exported import AlulaPresenceProtocol
