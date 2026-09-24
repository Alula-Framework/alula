// swift-tools-version: 6.3
import CompilerPluginSupport
import Foundation
import PackageDescription

// Alula: the framework core and the layers that build directly on it.
//
// One package, many products. Everything here shares the module/DI contract
// defined by AlulaCore, so a breaking change to that contract breaks all of
// it at once — keeping these targets together makes that a compile error in
// CI rather than a discovery weeks later in whichever adapter was not rebuilt.
//
// Backend drivers deliberately live elsewhere: alula-data carries the
// Postgres and Valkey stories so that nothing here forces a database or cache
// driver onto an application that does not use one.
let package = Package(
    name: "alula",
    platforms: [.macOS(.v15)],
    products: [
        // Configuration: the parser and vocabulary (dependency-free) and the
        // runtime facade over swift-configuration.
        .library(name: "AlulaConfigCore", targets: ["AlulaConfigCore"]),
        .library(name: "AlulaConfig", targets: ["AlulaConfig"]),

        // The framework core: container, modules, lifecycle, registration.
        .library(name: "AlulaCore", targets: ["AlulaCore"]),
        .plugin(name: "AlulaRegistrationPlugin", targets: ["AlulaRegistrationPlugin"]),

        // Web: routing, middleware, RequestContext, Response, WebSocket/SSE,
        // the ServerTransport seam, and the default HummingbirdCore-backed
        // transport as a peer of any third-party one.
        .library(name: "AlulaWeb", targets: ["AlulaWeb"]),
        .library(name: "AlulaTransport", targets: ["AlulaTransport"]),
        .library(name: "AlulaWebTesting", targets: ["AlulaWebTesting"]),

        // PubSub: Message, the DistributedPubSubAdapter seam, ClusteredPubSub.
        .library(name: "AlulaPubSub", targets: ["AlulaPubSub"]),
        .library(name: "AlulaPubSubTesting", targets: ["AlulaPubSubTesting"]),

        // Channels: per-connection lifecycle over PubSub and Web.
        .library(name: "AlulaChannels", targets: ["AlulaChannels"]),
        .library(name: "AlulaChannelsProtocol", targets: ["AlulaChannelsProtocol"]),
        .library(name: "AlulaChannelsClient", targets: ["AlulaChannelsClient"]),
        .library(name: "AlulaChannelsTesting", targets: ["AlulaChannelsTesting"]),

        // Presence: CRDT-merged "who is here", on top of PubSub and Channels.
        .library(name: "AlulaPresence", targets: ["AlulaPresence"]),
        .library(name: "AlulaPresenceProtocol", targets: ["AlulaPresenceProtocol"]),
        .library(name: "AlulaPresenceClient", targets: ["AlulaPresenceClient"]),

        // Sessions: the store seam, the session a handler works with, and the
        // in-memory default. No HTTP in it — the middleware and the cookie are
        // AlulaWeb's, which depends on this the way Channels depends on PubSub.
        .library(name: "AlulaSessions", targets: ["AlulaSessions"]),
        .library(name: "AlulaSessionsTesting", targets: ["AlulaSessionsTesting"]),

        // Rate limiting: the GCRA limiter and its store seam. Not an HTTP
        // concern — AlulaWeb's `RateLimiting` middleware is one consumer, a
        // login throttle is another, so the mechanism sits below both.
        .library(name: "AlulaRateLimit", targets: ["AlulaRateLimit"]),
        .library(name: "AlulaRateLimitTesting", targets: ["AlulaRateLimitTesting"]),

        // Operational endpoints: health probes and a topology dashboard.
        // Not metrics — that is a decision, recorded in Docs/actuator.md.
        .library(name: "AlulaActuator", targets: ["AlulaActuator"]),

        // MARK: Scheduler
        .library(name: "AlulaScheduler", targets: ["AlulaScheduler"]),
        .library(name: "AlulaCronCore", targets: ["AlulaCronCore"]),
        .library(name: "AlulaSchedulerTesting", targets: ["AlulaSchedulerTesting"]),

        // MARK: Mail
        // The mail seam and a development transport need nothing; the SMTP
        // client needs NIO and TLS, so it sits behind the "SMTP" trait.
        .library(name: "AlulaMail", targets: ["AlulaMail"]),
        .library(name: "AlulaMailTesting", targets: ["AlulaMailTesting"]),
        .library(name: "AlulaMailSMTP", targets: ["AlulaMailSMTP"]),

        // MARK: Queue
        // Durable background jobs: enqueue, retry, dead-letter. The seam is
        // dependency-free so alula-data can implement it with `traits: []`.
        .library(name: "AlulaQueue", targets: ["AlulaQueue"]),
        .library(name: "AlulaQueueTesting", targets: ["AlulaQueueTesting"]),

        // Authentication: a resource server. Token *validation* only, with a
        // TokenValidator seam so any issuer can be brought instead.
        .library(name: "AlulaSecurityCore", targets: ["AlulaSecurityCore"]),

        // Telemetry reporting: Alula's bridges from swift-telemetry's typed
        // events to swift-metrics, swift-distributed-tracing and swift-log,
        // and the module that wires them. Emitting is swift-telemetry's own
        // TelemetryCore, which libraries depend on without Alula (D44).
        .library(name: "AlulaTelemetryBridges", targets: ["AlulaTelemetryBridges"]),

        // Push: an APNs client — provider tokens, HTTP/2, typed answers.
        // Not gated on Web: a worker sending pushes needs no HTTP server.
        .library(name: "AlulaAPNS", targets: ["AlulaAPNS"]),
        .library(name: "AlulaAPNSTesting", targets: ["AlulaAPNSTesting"]),
    ],
    traits: [
        // Opt-in: a consumer names what it wants, and resolves nothing else.
        //
        //     traits: []                  container and lifecycle only
        //     traits: ["Web"]             + HTTP, WebSockets, Channels, Presence
        //     traits: ["Security"]        + authentication (implies Web)
        //
        // Requires Swift 6.3 or later. Through 6.2.x, SwiftPM did not resolve
        // the gated dependencies of a non-default trait enabled on a
        // *versioned* dependency and failed with "exhausted attempts to
        // resolve the dependencies graph" (swiftlang/swift-package-manager
        // #9286, fixed by #9269). Path dependencies always worked, so the
        // failure appeared only once this package was tagged and consumed for
        // real. Tools version 6.3 below makes the requirement explicit rather
        // than letting an older toolchain fail obscurely.
        .default(enabledTraits: []),
        .trait(
            name: "Web",
            description: "HTTP, WebSockets, SSE, Channels, Presence, and the actuator.",
            enabledTraits: ["Telemetry"]
        ),
        .trait(
            name: "Security",
            description: "OIDC/JWT resource-server authentication.",
            enabledTraits: ["Web"]
        ),
        // JWTKit and AsyncHTTPClient again — the same two packages Security
        // brings, so a Security consumer resolves nothing new — and nothing
        // from Web.
        .trait(
            name: "SMTP",
            description: "An SMTP client for AlulaMail: STARTTLS or implicit TLS, AUTH PLAIN/LOGIN."
        ),
        .trait(
            name: "APNS",
            description: "Apple Push Notification service client.",
            enabledTraits: ["Telemetry"]
        ),
        // Reporting telemetry: swift-metrics and swift-distributed-tracing.
        .trait(
            name: "Telemetry",
            description: "Telemetry reporting: swift-metrics, tracing and logging bridges."
        ),
    ],
    dependencies: [
        // Dependency policy: Apple-adjacent and SSWG-blessed only, with one
        // deliberate exception (jwt-kit), noted at its use site. Password
        // hashing's C dependency (the Argon2 reference implementation) is
        // vendored rather than an external package — see the `CArgon2`
        // target below and D37 in DECISIONS.md.
        .package(url: "https://github.com/apple/swift-configuration.git", from: "1.2.0"),
        .package(url: "https://github.com/apple/swift-log.git", from: "1.6.0"),
        .package(url: "https://github.com/apple/swift-http-types.git", from: "1.3.0"),
        .package(url: "https://github.com/apple/swift-service-context.git", from: "1.1.0"),
        // Typed events and spans. Its own package so a library can emit
        // without depending on Alula (D44); every use below is trait-gated,
        // so a lean consumer does not resolve it.
        .package(url: "https://github.com/Alula-Framework/swift-telemetry.git", from: "0.1.0"),
        .package(url: "https://github.com/apple/swift-distributed-tracing.git", from: "1.1.0"),
        .package(url: "https://github.com/apple/swift-nio.git", from: "2.77.0"),
        .package(url: "https://github.com/swift-server/swift-service-lifecycle.git", from: "2.6.0"),
        // swift-syntax bumps its major with each Swift release; the open
        // range is the community convention for macro packages.
        .package(url: "https://github.com/swiftlang/swift-syntax.git", "601.0.0"..<"999.0.0"),
        // The default transport wraps HummingbirdCore — explicitly factored
        // as router-on-top-of-core, a public versioned package intended for
        // exactly this use rather than an internal reached into from outside.
        .package(url: "https://github.com/hummingbird-project/hummingbird.git", from: "2.5.0"),
        .package(
            url: "https://github.com/hummingbird-project/hummingbird-websocket.git", from: "2.2.0"),
        // TLS: used by the transport, and by the web test suite to generate a
        // throwaway self-signed certificate per run — so no private key is
        // ever committed and no fixture can expire.
        .package(url: "https://github.com/apple/swift-nio-ssl.git", from: "2.37.0"),
        .package(url: "https://github.com/apple/swift-certificates.git", from: "1.19.0"),
        // The one security-critical primitive is delegated: JWTKit is SSWG
        // Graduated and SwiftCrypto-backed. Alula owns orchestration only.
        .package(url: "https://github.com/vapor/jwt-kit.git", from: "5.6.0"),
        // SHA-256 for OIDC sign-in's PKCE challenge. Already resolved through
        // jwt-kit for every Security consumer, at the same floor, so naming it
        // adds nothing to resolve; AlulaWeb's own SHA256 is a content
        // checksum, deliberately not used for anything security-relevant.
        .package(url: "https://github.com/apple/swift-crypto.git", from: "4.1.0"),
        // The metrics facade — the SSWG one — for the counters sessions,
        // sign-in, one-time tokens and APNs emit. Resolved already under Web
        // through Hummingbird, at the same floor; nothing here picks a
        // backend, the application bootstraps one.
        .package(url: "https://github.com/apple/swift-metrics.git", from: "2.9.0"),
        .package(url: "https://github.com/swift-server/async-http-client.git", from: "1.21.0"),
    ],
    targets: [
        // MARK: Configuration

        .target(
            name: "AlulaConfigCore", path: "Sources/Config/AlulaConfigCore",
            swiftSettings: [.swiftLanguageMode(.v6)]),
        .target(
            name: "AlulaConfig",
            dependencies: [
                "AlulaConfigCore",
                .product(name: "Configuration", package: "swift-configuration"),
            ],
            path: "Sources/Config/AlulaConfig",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),

        // MARK: Core

        // The registration macros' shared model: one `InjectedProperty`, one
        // parenthesisation rule, one constructor-injection generator. It was
        // written three times before this, each copy commented as mirroring
        // the others.
        .target(
            name: "AlulaMacroSupport",
            dependencies: [
                .product(name: "SwiftSyntax", package: "swift-syntax"),
                .product(name: "SwiftSyntaxBuilder", package: "swift-syntax"),
            ],
            path: "Sources/Core/AlulaMacroSupport"
        ),
        .macro(
            name: "AlulaCoreMacrosImpl",
            dependencies: [
                "AlulaMacroSupport",
                "AlulaConfigCore",
                .product(name: "SwiftSyntax", package: "swift-syntax"),
                .product(name: "SwiftSyntaxMacros", package: "swift-syntax"),
                .product(name: "SwiftCompilerPlugin", package: "swift-syntax"),
                .product(name: "SwiftDiagnostics", package: "swift-syntax"),
                .product(name: "SwiftSyntaxBuilder", package: "swift-syntax"),
            ],
            path: "Sources/Core/AlulaCoreMacrosImpl"
        ),
        // Code generator invoked by the build tool plugin. Kept free of
        // swift-argument-parser deliberately (one positional arg: manifest
        // path). It parses alula.yaml with the *same* parser the runtime
        // uses, so the compile-time key check can never disagree with runtime
        // resolution about what keys a file defines — hence AlulaConfigCore
        // rather than AlulaConfig: a build tool's dependencies are paid for
        // by every consumer's build, and the check needs the parser, not the
        // provider stack.
        .executableTarget(
            name: "alula-registration-gen",
            dependencies: [
                "AlulaConfigCore",
                "AlulaRouteScan",
                .product(name: "SwiftSyntax", package: "swift-syntax"),
                .product(name: "SwiftParser", package: "swift-syntax"),
            ],
            path: "Sources/Core/alula-registration-gen"
        ),
        .plugin(
            name: "AlulaRegistrationPlugin",
            capability: .buildTool(),
            dependencies: ["alula-registration-gen"]
        ),
        .target(
            name: "AlulaCore",
            dependencies: [
                "AlulaCoreMacrosImpl",
                "AlulaConfig",
                .product(name: "ServiceLifecycle", package: "swift-service-lifecycle"),
                .product(name: "Logging", package: "swift-log"),
            ],
            // Strict concurrency is the default under tools 6.x; kept explicit
            // as documentation of intent.
            path: "Sources/Core/AlulaCore",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),

        // MARK: Web

        // Route scanning, shared by the two things that need it: the
        // `@Controller` macro expanding one file, and
        // `alula-registration-gen` building the static route manifest across
        // a whole target. One parser, so the paths, the validation and the
        // messages cannot drift between them. Depends on SwiftSyntax but
        // *not* SwiftSyntaxMacros — that coupling is what kept the route
        // table invisible to the generator.
        .target(
            name: "AlulaRouteScan",
            dependencies: [
                .product(name: "SwiftSyntax", package: "swift-syntax")
            ],
            path: "Sources/Web/AlulaRouteScan"
        ),
        .macro(
            name: "AlulaWebMacrosImpl",
            dependencies: [
                "AlulaMacroSupport",
                "AlulaRouteScan",
                .product(name: "SwiftSyntax", package: "swift-syntax"),
                .product(name: "SwiftSyntaxMacros", package: "swift-syntax"),
                .product(name: "SwiftCompilerPlugin", package: "swift-syntax"),
                .product(name: "SwiftDiagnostics", package: "swift-syntax"),
                .product(name: "SwiftSyntaxBuilder", package: "swift-syntax"),
            ],
            path: "Sources/Web/AlulaWebMacrosImpl"
        ),
        .target(
            name: "AlulaWeb",
            dependencies: [
                .product(name: "TelemetryMacros", package: "swift-telemetry", condition: .when(traits: ["Web"])),
                .product(name: "TelemetryCore", package: "swift-telemetry", condition: .when(traits: ["Web"])),
                .target(name: "AlulaTelemetryBridges", condition: .when(traits: ["Web"])),
                .target(name: "AlulaWebMacrosImpl", condition: .when(traits: ["Web"])),
                "AlulaCore",
                "AlulaSessions",
                "AlulaRateLimit",
                .product(
                    name: "HTTPTypes", package: "swift-http-types",
                    condition: .when(traits: ["Web"])),
                .product(name: "Logging", package: "swift-log"),
                .product(
                    name: "ServiceContextModule", package: "swift-service-context",
                    condition: .when(traits: ["Web"])),
                .product(
                    name: "Tracing", package: "swift-distributed-tracing",
                    condition: .when(traits: ["Web"])),
                .product(name: "ServiceLifecycle", package: "swift-service-lifecycle"),
                .target(name: "CAlulaZlib", condition: .when(traits: ["Web"])),
            ],
            path: "Sources/Web/AlulaWeb",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        // The system zlib, for `ResponseCompression`. A systemLibrary rather
        // than a package: zlib is present wherever Swift is (corelibs
        // Foundation already links it), so this costs a modulemap instead of
        // a dependency. Lean container images may still need the headers —
        // `zlib1g-dev` on Debian, which the official Swift images carry.
        .systemLibrary(
            name: "CAlulaZlib",
            path: "Sources/Web/CAlulaZlib",
            providers: [.apt(["zlib1g-dev"]), .yum(["zlib-devel"]), .brew(["zlib"])]
        ),
        // The ONLY target in Alula that knows what the transport wraps.
        // Depends on AlulaWeb one-way — routing and middleware never
        // reference this target.
        .target(
            name: "AlulaTransport",
            dependencies: [
                .target(name: "AlulaWeb", condition: .when(traits: ["Web"])),
                .product(
                    name: "HummingbirdCore", package: "hummingbird",
                    condition: .when(traits: ["Web"])),
                .product(
                    name: "HummingbirdWebSocket", package: "hummingbird-websocket",
                    condition: .when(traits: ["Web"])),
                .product(
                    name: "HummingbirdTLS", package: "hummingbird",
                    condition: .when(traits: ["Web"])),
                .product(name: "NIOCore", package: "swift-nio", condition: .when(traits: ["Web"])),
                .product(
                    name: "NIOSSL", package: "swift-nio-ssl", condition: .when(traits: ["Web"])),
                .product(
                    name: "HTTPTypes", package: "swift-http-types",
                    condition: .when(traits: ["Web"])),
                .product(name: "ServiceLifecycle", package: "swift-service-lifecycle"),
                .product(name: "Logging", package: "swift-log"),
            ],
            path: "Sources/Web/AlulaTransport",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .target(
            name: "AlulaWebTesting",
            dependencies: [
                .target(name: "AlulaWeb", condition: .when(traits: ["Web"])),
                "AlulaCore",
                .product(name: "Logging", package: "swift-log"),
            ],
            path: "Sources/Web/AlulaWebTesting",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),

        // MARK: PubSub

        .target(
            name: "AlulaPubSub",
            dependencies: [
                "AlulaCore",
                .product(name: "Logging", package: "swift-log"),
                .product(name: "ServiceLifecycle", package: "swift-service-lifecycle"),
            ],
            path: "Sources/PubSub/AlulaPubSub",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .target(
            name: "AlulaPubSubTesting",
            dependencies: ["AlulaPubSub"],
            path: "Sources/PubSub/AlulaPubSubTesting",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),

        // MARK: Channels

        .target(
            name: "AlulaChannelsProtocol", path: "Sources/Channels/AlulaChannelsProtocol",
            swiftSettings: [.swiftLanguageMode(.v6)]),
        .target(
            name: "AlulaChannels",
            dependencies: [
                "AlulaChannelsProtocol", "AlulaCore", "AlulaPubSub",
                .target(name: "AlulaWeb", condition: .when(traits: ["Web"])),
                .product(name: "Logging", package: "swift-log"),
            ],
            path: "Sources/Channels/AlulaChannels",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .target(
            name: "AlulaChannelsClient",
            dependencies: [
                "AlulaChannelsProtocol",
                .product(name: "Logging", package: "swift-log"),
            ],
            path: "Sources/Channels/AlulaChannelsClient",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .target(
            name: "AlulaChannelsTesting",
            dependencies: [
                .target(name: "AlulaChannels", condition: .when(traits: ["Web"])),
                "AlulaChannelsClient",
                .target(name: "AlulaWebTesting", condition: .when(traits: ["Web"])),
            ],
            path: "Sources/Channels/AlulaChannelsTesting",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),

        // MARK: Presence

        .target(
            name: "AlulaPresenceProtocol",
            dependencies: ["AlulaChannelsProtocol"],
            path: "Sources/Presence/AlulaPresenceProtocol",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .target(
            name: "AlulaPresence",
            dependencies: [
                "AlulaPresenceProtocol", "AlulaCore", "AlulaPubSub",
                .target(name: "AlulaChannels", condition: .when(traits: ["Web"])),
                .product(name: "Logging", package: "swift-log"),
                .product(name: "ServiceLifecycle", package: "swift-service-lifecycle"),
            ],
            path: "Sources/Presence/AlulaPresence",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .target(
            name: "AlulaPresenceClient",
            dependencies: ["AlulaPresenceProtocol", "AlulaChannelsClient"],
            path: "Sources/Presence/AlulaPresenceClient",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),

        // MARK: Scheduler

        .target(
            name: "AlulaCronCore", path: "Sources/Scheduler/AlulaCronCore",
            swiftSettings: [.swiftLanguageMode(.v6)]),
        .macro(
            name: "AlulaSchedulerMacrosImpl",
            dependencies: [
                "AlulaMacroSupport",
                "AlulaCronCore",
                .product(name: "SwiftSyntax", package: "swift-syntax"),
                .product(name: "SwiftSyntaxMacros", package: "swift-syntax"),
                .product(name: "SwiftCompilerPlugin", package: "swift-syntax"),
                .product(name: "SwiftDiagnostics", package: "swift-syntax"),
                .product(name: "SwiftSyntaxBuilder", package: "swift-syntax"),
            ],
            path: "Sources/Scheduler/AlulaSchedulerMacrosImpl",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .target(
            name: "AlulaScheduler",
            dependencies: [
                "AlulaCore",
                "AlulaCronCore",
                "AlulaSchedulerMacrosImpl",
                .product(name: "Logging", package: "swift-log"),
                .product(name: "ServiceLifecycle", package: "swift-service-lifecycle"),
            ],
            path: "Sources/Scheduler/AlulaScheduler",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),

        .target(
            name: "AlulaSchedulerTesting",
            dependencies: ["AlulaScheduler"],
            path: "Sources/Scheduler/AlulaSchedulerTesting",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),

        // MARK: Queue

        .target(
            name: "AlulaQueue",
            dependencies: [
                "AlulaCore",
                .product(name: "Logging", package: "swift-log"),
                .product(name: "ServiceLifecycle", package: "swift-service-lifecycle"),
            ],
            path: "Sources/Queue/AlulaQueue",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .target(
            name: "AlulaQueueTesting",
            dependencies: ["AlulaQueue"],
            path: "Sources/Queue/AlulaQueueTesting",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),

        // MARK: Mail

        .target(
            name: "AlulaMail",
            dependencies: [
                "AlulaCore", "AlulaQueue",
                .product(name: "Logging", package: "swift-log"),
            ],
            path: "Sources/Mail/AlulaMail",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .target(
            name: "AlulaMailTesting",
            dependencies: ["AlulaMail"],
            path: "Sources/Mail/AlulaMailTesting",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .target(
            name: "AlulaMailSMTP",
            dependencies: [
                "AlulaCore", "AlulaMail",
                .product(name: "Logging", package: "swift-log"),
                .product(name: "NIOCore", package: "swift-nio", condition: .when(traits: ["SMTP"])),
                .product(name: "NIOPosix", package: "swift-nio", condition: .when(traits: ["SMTP"])),
                .product(
                    name: "NIOSSL", package: "swift-nio-ssl", condition: .when(traits: ["SMTP"])),
            ],
            path: "Sources/Mail/AlulaMailSMTP",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),

        // MARK: Sessions

        // Dependency-free on purpose: alula-data implements `SessionStore`
        // over Valkey, and it depends on alula with no traits so that a
        // cache-only consumer never resolves the HTTP stack. A seam that
        // needed AlulaWeb would need a conditional trait from alula-data —
        // a pattern nothing here uses. Same shape as AlulaPubSub's adapter
        // seam.
        .target(
            name: "AlulaSessions", path: "Sources/Sessions/AlulaSessions",
            swiftSettings: [.swiftLanguageMode(.v6)]),
        .target(
            name: "AlulaSessionsTesting",
            dependencies: ["AlulaSessions"],
            path: "Sources/Sessions/AlulaSessionsTesting",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),

        // MARK: Rate limiting

        // Depends on AlulaCore for `Configuration` and `AlulaModule`, and on
        // nothing else: alula-data resolves alula with `traits: []`, so an
        // adapter living there can implement this seam without dragging the
        // HTTP stack behind it. Same posture as AlulaCache.
        .target(
            name: "AlulaRateLimit",
            dependencies: ["AlulaCore"],
            path: "Sources/RateLimit/AlulaRateLimit",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .target(
            name: "AlulaRateLimitTesting",
            dependencies: ["AlulaRateLimit"],
            path: "Sources/RateLimit/AlulaRateLimitTesting",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),

        // MARK: Actuator

        .target(
            name: "AlulaActuator",
            dependencies: [
                .target(name: "AlulaWeb", condition: .when(traits: ["Web"])), "AlulaCore",
            ],
            path: "Sources/Actuator/AlulaActuator",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),

        // MARK: Telemetry

        // Reporting: swift-metrics, swift-distributed-tracing and swift-log
        // bridges, and the module that wires them from configuration. Behind
        // the Telemetry trait, which Web and APNS imply — both already bring
        // swift-metrics and tracing, so neither resolves anything new.
        .target(
            name: "AlulaTelemetryBridges",
            dependencies: [
                "AlulaCore",
                .product(name: "TelemetryCore", package: "swift-telemetry", condition: .when(traits: ["Telemetry"])),
                .product(name: "CoreMetrics", package: "swift-metrics", condition: .when(traits: ["Telemetry"])),
                .product(
                    name: "Tracing", package: "swift-distributed-tracing",
                    condition: .when(traits: ["Telemetry"])),
                .product(name: "Logging", package: "swift-log"),
                .product(name: "ServiceLifecycle", package: "swift-service-lifecycle"),
            ],
            path: "Sources/Telemetry/AlulaTelemetryBridges",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "AlulaTelemetryBridgesTests",
            dependencies: [
                .target(name: "AlulaTelemetryBridges", condition: .when(traits: ["Telemetry"])),
                "AlulaCore",
                .product(name: "TelemetryMacros", package: "swift-telemetry", condition: .when(traits: ["Telemetry"])),
                .product(name: "MetricsTestKit", package: "swift-metrics", condition: .when(traits: ["Telemetry"])),
                .product(name: "Tracing", package: "swift-distributed-tracing", condition: .when(traits: ["Telemetry"])),
                .product(name: "InMemoryTracing", package: "swift-distributed-tracing", condition: .when(traits: ["Telemetry"])),
            ],
            path: "Tests/Telemetry/AlulaTelemetryBridgesTests",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),

        // MARK: Security

        .target(
            name: "AlulaSecurityCore",
            dependencies: [
                "AlulaCore", "AlulaSessions", "AlulaRateLimit",
                .product(name: "TelemetryMacros", package: "swift-telemetry", condition: .when(traits: ["Security"])),
                .product(name: "TelemetryCore", package: "swift-telemetry", condition: .when(traits: ["Security"])),
                .target(name: "AlulaTelemetryBridges", condition: .when(traits: ["Security"])),
                .target(name: "AlulaWeb", condition: .when(traits: ["Web"])),
                .product(
                    name: "JWTKit", package: "jwt-kit", condition: .when(traits: ["Security"])),
                .product(
                    name: "AsyncHTTPClient", package: "async-http-client",
                    condition: .when(traits: ["Security"])),
                .target(name: "CArgon2", condition: .when(traits: ["Security"])),
                .product(name: "Crypto", package: "swift-crypto", condition: .when(traits: ["Security"])),
                .product(name: "Logging", package: "swift-log"),
                .product(name: "ServiceLifecycle", package: "swift-service-lifecycle"),
                .product(
                    name: "HTTPTypes", package: "swift-http-types",
                    condition: .when(traits: ["Web"])),
                .product(name: "NIOCore", package: "swift-nio", condition: .when(traits: ["Web"])),
                .product(
                    name: "NIOFoundationCompat", package: "swift-nio",
                    condition: .when(traits: ["Web"])),
            ],
            path: "Sources/Security/AlulaSecurityCore",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        // The Argon2 reference implementation (RFC 9106, winner of the
        // Password Hashing Competition), vendored rather than depended on:
        // the upstream repository carries no semver tags, and pinning it by
        // `revision:` made every one of Alula's own tagged releases with
        // `Security` on unresolvable by a consumer using an ordinary
        // `from:` requirement — SwiftPM refuses a version-pinned package's
        // dependency on one that is not. See D37 in DECISIONS.md.
        //
        // These are the six files upstream's own `Package.swift` builds as
        // its `argon2` product — the portable reference path, no SIMD, no
        // CLI or benchmark tooling — copied verbatim; `NOTICE.md` in this
        // target's directory names the exact commit. `publicHeadersPath` is
        // named explicitly though it matches SwiftPM's own default, because
        // a target with no Swift in it is easy to misread as needing none.
        .target(
            name: "CArgon2",
            path: "Sources/Security/CArgon2",
            exclude: ["NOTICE.md", "LICENSE"],
            publicHeadersPath: "include"
        ),

        // MARK: Push

        .target(
            name: "AlulaAPNS",
            dependencies: [
                "AlulaCore",
                .product(name: "TelemetryMacros", package: "swift-telemetry", condition: .when(traits: ["APNS"])),
                .product(name: "TelemetryCore", package: "swift-telemetry", condition: .when(traits: ["APNS"])),
                .target(name: "AlulaTelemetryBridges", condition: .when(traits: ["APNS"])),
                .product(name: "JWTKit", package: "jwt-kit", condition: .when(traits: ["APNS"])),
                .product(
                    name: "AsyncHTTPClient", package: "async-http-client",
                    condition: .when(traits: ["APNS"])),
                .product(name: "NIOCore", package: "swift-nio", condition: .when(traits: ["APNS"])),
                .product(
                    name: "NIOHTTP1", package: "swift-nio", condition: .when(traits: ["APNS"])),
                .product(
                    name: "NIOFoundationCompat", package: "swift-nio",
                    condition: .when(traits: ["APNS"])),
                .product(name: "Logging", package: "swift-log"),
            ],
            path: "Sources/Push/AlulaAPNS",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .target(
            name: "AlulaAPNSTesting",
            dependencies: [.target(name: "AlulaAPNS", condition: .when(traits: ["APNS"]))],
            path: "Sources/Push/AlulaAPNSTesting",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),

        // MARK: Tests

        .testTarget(
            name: "AlulaMailTests",
            dependencies: [
                "AlulaMail", "AlulaMailTesting", "AlulaQueue", "AlulaQueueTesting", "AlulaCore",
            ],
            path: "Tests/Mail/AlulaMailTests",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "AlulaMailSMTPTests",
            dependencies: [
                "AlulaMail", "AlulaCore",
                .target(name: "AlulaMailSMTP", condition: .when(traits: ["SMTP"])),
                .product(name: "NIOCore", package: "swift-nio", condition: .when(traits: ["SMTP"])),
                .product(name: "NIOPosix", package: "swift-nio", condition: .when(traits: ["SMTP"])),
            ],
            path: "Tests/Mail/AlulaMailSMTPTests",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "AlulaQueueTests",
            dependencies: [
                "AlulaQueue", "AlulaQueueTesting", "AlulaCore",
                .product(name: "Logging", package: "swift-log"),
                .product(name: "ServiceLifecycle", package: "swift-service-lifecycle"),
            ],
            path: "Tests/Queue/AlulaQueueTests",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "AlulaConfigTests",
            dependencies: ["AlulaConfig"],
            path: "Tests/Config/AlulaConfigTests",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "AlulaCoreTests",
            dependencies: [
                "AlulaCore",
                .product(name: "ServiceLifecycle", package: "swift-service-lifecycle"),
                // `InMemoryProvider`, for the one behaviour of the
                // adapter-presence guard that needs a provider holding a
                // non-scalar: a key that fails to *decode* still counts as
                // configured.
                .product(name: "Configuration", package: "swift-configuration"),
            ],
            path: "Tests/Core/AlulaCoreTests"
        ),
        // Macro fixture suites use SwiftSyntaxMacrosGenericTestSupport, not
        // SwiftSyntaxMacrosTestSupport: the latter reports through XCTFail and
        // would force these suites onto XCTest. The generic variant hands
        // failures back, so they record as swift-testing issues like every
        // other suite here. See Tests/*/SwiftTestingBridge.swift.
        .testTarget(
            name: "AlulaCoreMacroTests",
            dependencies: [
                "AlulaCoreMacrosImpl",
                .product(name: "SwiftSyntaxMacros", package: "swift-syntax"),
                // MacroSpec — carries declared conformances into assertMacroExpansion.
                .product(name: "SwiftSyntaxMacroExpansion", package: "swift-syntax"),
                .product(name: "SwiftSyntaxMacrosGenericTestSupport", package: "swift-syntax"),
            ],
            path: "Tests/Core/AlulaCoreMacroTests"
        ),
        .testTarget(
            name: "AlulaRegistrationGenTests",
            dependencies: ["alula-registration-gen"],
            path: "Tests/Core/AlulaRegistrationGenTests",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "AlulaWebTests",
            dependencies: [
                .target(name: "AlulaWeb", condition: .when(traits: ["Web"])),
                .target(name: "AlulaWebTesting", condition: .when(traits: ["Web"])), "AlulaCore",
                "AlulaSessions", "AlulaSessionsTesting",
                .product(name: "TelemetryCore", package: "swift-telemetry", condition: .when(traits: ["Web"])),
                .product(name: "TelemetryTesting", package: "swift-telemetry", condition: .when(traits: ["Web"])),
                "AlulaRateLimit", "AlulaRateLimitTesting",
                .product(name: "ServiceLifecycle", package: "swift-service-lifecycle"),
                // Inflating what ResponseCompression produced: the only claim
                // worth testing is that a real decoder reads it back.
                .target(name: "CAlulaZlib", condition: .when(traits: ["Web"])),
            ],
            path: "Tests/Web/AlulaWebTests"
        ),
        // Real-socket integration suite: HTTP round-trips, SSE streaming,
        // WebSocket upgrade against a bound AlulaTransport.
        .testTarget(
            name: "AlulaTransportTests",
            dependencies: [
                .target(name: "AlulaTransport", condition: .when(traits: ["Web"])),
                .target(name: "AlulaWeb", condition: .when(traits: ["Web"])),
                .target(name: "AlulaWebTesting", condition: .when(traits: ["Web"])),
                "AlulaSessions", "AlulaSessionsTesting", "AlulaRateLimit", "AlulaRateLimitTesting",
                // The Keycloak integration suite plays the browser itself.
                .product(
                    name: "AsyncHTTPClient", package: "async-http-client",
                    condition: .when(traits: ["Security"])),
                .product(
                    name: "NIOFoundationCompat", package: "swift-nio", condition: .when(traits: ["Web"])),
                .product(name: "NIOCore", package: "swift-nio", condition: .when(traits: ["Web"])),
                .product(name: "NIOPosix", package: "swift-nio", condition: .when(traits: ["Web"])),
                .product(name: "NIOHTTP1", package: "swift-nio", condition: .when(traits: ["Web"])),
                .product(
                    name: "NIOWebSocket", package: "swift-nio", condition: .when(traits: ["Web"])),
                .product(
                    name: "NIOSSL", package: "swift-nio-ssl", condition: .when(traits: ["Web"])),
                .product(
                    name: "X509", package: "swift-certificates", condition: .when(traits: ["Web"])),
                .product(name: "ServiceLifecycle", package: "swift-service-lifecycle"),
            ],
            path: "Tests/Web/AlulaTransportTests"
        ),
        .testTarget(
            name: "AlulaWebMacroTests",
            dependencies: [
                .target(name: "AlulaWebMacrosImpl", condition: .when(traits: ["Web"])),
                "AlulaCoreMacrosImpl",
                .product(name: "SwiftSyntaxMacros", package: "swift-syntax"),
                .product(name: "SwiftSyntaxMacroExpansion", package: "swift-syntax"),
                .product(name: "SwiftSyntaxMacrosGenericTestSupport", package: "swift-syntax"),
            ],
            path: "Tests/Web/AlulaWebMacroTests"
        ),
        .testTarget(
            name: "AlulaPubSubTests",
            dependencies: [
                "AlulaPubSub", "AlulaPubSubTesting", "AlulaCore",
                .product(name: "ServiceLifecycle", package: "swift-service-lifecycle"),
                .product(name: "Logging", package: "swift-log"),
            ],
            path: "Tests/PubSub/AlulaPubSubTests"
        ),
        .testTarget(
            name: "AlulaChannelsTests",
            dependencies: [
                .target(name: "AlulaChannels", condition: .when(traits: ["Web"])),
                .target(name: "AlulaChannelsTesting", condition: .when(traits: ["Web"])),
                "AlulaCore",
                "AlulaPubSub", "AlulaPubSubTesting",
                .target(name: "AlulaWeb", condition: .when(traits: ["Web"])),
                .target(name: "AlulaWebTesting", condition: .when(traits: ["Web"])),
            ],
            path: "Tests/Channels/AlulaChannelsTests"
        ),
        .testTarget(
            name: "AlulaChannelsClientTests",
            dependencies: [
                "AlulaChannelsClient",
                .target(name: "AlulaChannelsTesting", condition: .when(traits: ["Web"])),
                .target(name: "AlulaWebTesting", condition: .when(traits: ["Web"])),
            ],
            path: "Tests/Channels/AlulaChannelsClientTests"
        ),
        .testTarget(
            name: "AlulaChannelsE2ETests",
            dependencies: [
                .target(name: "AlulaChannels", condition: .when(traits: ["Web"])),
                "AlulaChannelsClient", "AlulaCore", "AlulaPubSub",
                .target(name: "AlulaWeb", condition: .when(traits: ["Web"])),
                .target(name: "AlulaWebTesting", condition: .when(traits: ["Web"])),
                .target(name: "AlulaTransport", condition: .when(traits: ["Web"])),
                .product(
                    name: "HummingbirdWSClient", package: "hummingbird-websocket",
                    condition: .when(traits: ["Web"])),
            ],
            path: "Tests/Channels/AlulaChannelsE2ETests"
        ),
        .testTarget(
            name: "AlulaPresenceTests",
            dependencies: [
                .target(name: "AlulaPresence", condition: .when(traits: ["Web"])),
                "AlulaPresenceClient", "AlulaCore", "AlulaPubSub",
                "AlulaPubSubTesting",
                .target(name: "AlulaChannels", condition: .when(traits: ["Web"])),
                .target(name: "AlulaChannelsTesting", condition: .when(traits: ["Web"])),
                .target(name: "AlulaWeb", condition: .when(traits: ["Web"])),
                .target(name: "AlulaWebTesting", condition: .when(traits: ["Web"])),
                .product(name: "ServiceLifecycle", package: "swift-service-lifecycle"),
                .product(name: "Logging", package: "swift-log"),
            ],
            path: "Tests/Presence/AlulaPresenceTests"
        ),
        .testTarget(
            name: "AlulaActuatorTests",
            dependencies: [
                .target(name: "AlulaActuator", condition: .when(traits: ["Web"])),
                .target(name: "AlulaWeb", condition: .when(traits: ["Web"])),
                .target(name: "AlulaWebTesting", condition: .when(traits: ["Web"])), "AlulaCore",
                .product(name: "ServiceLifecycle", package: "swift-service-lifecycle"),
            ],
            path: "Tests/Actuator/AlulaActuatorTests"
        ),
        .testTarget(
            name: "AlulaSchedulerMacroTests",
            dependencies: [
                "AlulaSchedulerMacrosImpl",
                .product(name: "SwiftSyntaxMacros", package: "swift-syntax"),
                .product(name: "SwiftSyntaxMacroExpansion", package: "swift-syntax"),
                .product(name: "SwiftSyntaxMacrosGenericTestSupport", package: "swift-syntax"),
            ],
            path: "Tests/Scheduler/AlulaSchedulerMacroTests"
        ),
        .testTarget(
            name: "AlulaSchedulerTests",
            dependencies: ["AlulaScheduler", "AlulaSchedulerTesting"],
            path: "Tests/Scheduler/AlulaSchedulerTests",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "AlulaRateLimitTests",
            dependencies: ["AlulaRateLimit", "AlulaRateLimitTesting", "AlulaCore"],
            path: "Tests/RateLimit/AlulaRateLimitTests",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "AlulaSessionsTests",
            dependencies: ["AlulaSessions", "AlulaSessionsTesting"],
            path: "Tests/Sessions/AlulaSessionsTests",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "AlulaAPNSTests",
            dependencies: [
                .target(name: "AlulaAPNS", condition: .when(traits: ["APNS"])),
                .product(name: "TelemetryCore", package: "swift-telemetry", condition: .when(traits: ["APNS"])),
                .product(name: "TelemetryTesting", package: "swift-telemetry", condition: .when(traits: ["APNS"])),
                .target(name: "AlulaAPNSTesting", condition: .when(traits: ["APNS"])),
                "AlulaCore",
                .product(name: "JWTKit", package: "jwt-kit", condition: .when(traits: ["APNS"])),
            ],
            path: "Tests/Push/AlulaAPNSTests",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "AlulaSecurityCoreTests",
            dependencies: [
                .target(name: "AlulaSecurityCore", condition: .when(traits: ["Security"])),
                .product(name: "TelemetryCore", package: "swift-telemetry", condition: .when(traits: ["Security"])),
                .product(name: "TelemetryTesting", package: "swift-telemetry", condition: .when(traits: ["Security"])),
                .target(name: "AlulaWeb", condition: .when(traits: ["Web"])),
                .target(name: "AlulaWebTesting", condition: .when(traits: ["Web"])), "AlulaCore",
                "AlulaSessions", "AlulaSessionsTesting",
                .product(
                    name: "JWTKit", package: "jwt-kit", condition: .when(traits: ["Security"])),
                .target(name: "CArgon2", condition: .when(traits: ["Security"])),
                .product(
                    name: "HTTPTypes", package: "swift-http-types",
                    condition: .when(traits: ["Web"])),
            ],
            path: "Tests/Security/AlulaSecurityCoreTests",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ]
)

// Documentation tooling only, gated so that consumers never resolve it.
//
//     ALULA_BUILD_DOCS=1 swift package generate-documentation
if ProcessInfo.processInfo.environment["ALULA_BUILD_DOCS"] != nil {
    package.dependencies.append(
        .package(url: "https://github.com/swiftlang/swift-docc-plugin", from: "1.3.0")
    )
}

// Strict warnings, opt-in and scoped to Alula's own targets.
//
// `swift build -Xswiftc -warnings-as-errors` cannot be used for this: it
// applies to every module in the build, dependencies included, so a warning
// in third-party code that a newer compiler has already fixed fails the
// build. This setting reaches only the targets declared above.
//
//     ALULA_STRICT_WARNINGS=1 swift build --enable-all-traits
if ProcessInfo.processInfo.environment["ALULA_STRICT_WARNINGS"] != nil {
    // Plugin and system targets both reject build settings outright — a
    // system library is a modulemap over headers somebody else compiled, so
    // there is nothing here to warn about. Omitting `.system` failed only
    // under this environment variable, which is to say only in CI.
    for target in package.targets where target.type != .plugin && target.type != .system {
        var settings = target.swiftSettings ?? []
        settings.append(.treatAllWarnings(as: .error))
        target.swiftSettings = settings
    }
}
