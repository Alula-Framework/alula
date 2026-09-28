// One import for every Alula testing module the enabled traits allow.
//
// Each re-export sits behind the trait its module requires, and Package.swift
// gates the matching dependency on the same trait, so a `traits: []` consumer
// gets the dependency-free modules and resolves nothing from Web, HTTPClient
// or APNS. The individual `*Testing` products remain for a build that wants
// fewer modules compiled.

@_exported import AlulaMailTesting
@_exported import AlulaPubSubTesting
@_exported import AlulaQueueTesting
@_exported import AlulaRateLimitTesting
@_exported import AlulaSchedulerTesting
@_exported import AlulaSessionsTesting

#if Web
@_exported import AlulaChannelsTesting
@_exported import AlulaWebTesting
#endif

#if HTTPClient
@_exported import AlulaHTTPClientTesting
#endif

#if APNS
@_exported import AlulaAPNSTesting
#endif
