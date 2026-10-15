// The package half of `SWIFT_APPROACHABLE_CONCURRENCY`, checked rather than
// trusted: `.enableUpcomingFeature` with a misspelled name compiles clean and
// leaves the feature off, and then this module and the Xcode targets disagree
// about where every `nonisolated async` function runs. See docs/concurrency.md.
#if !hasFeature(NonisolatedNonsendingByDefault)
#error("NonisolatedNonsendingByDefault is off; Package.swift must enable it")
#endif
#if !hasFeature(InferIsolatedConformances)
#error("InferIsolatedConformances is off; Package.swift must enable it")
#endif
