# Concurrency settings (verified 4 Sept 2026)

> Moved verbatim from `CLAUDE.md` on 1 Oct 2026. Where the text says "this file", "above" or "below", it means the old single file; a **bold** section name can be found with `grep -r docs/`.

The package and the Xcode targets must state the same thing, or a file changes
behaviour when it moves across the seam.

| where | settings |
|---|---|
| Xcode targets | `SWIFT_VERSION = 6.0`, `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`, `SWIFT_UPCOMING_FEATURE_MEMBER_IMPORT_VISIBILITY = YES` |
| package | `swiftLanguageModes: [.v6]`, `.enableUpcomingFeature("MemberImportVisibility")` on every target, `.defaultIsolation(MainActor.self)` on `BleatUI` only |

- **`RemoteList` writes an empty `deinit`, and deleting it breaks the archive.**
  `swift-frontend` 6.3.3 segfaults optimising `BleatUI` without it — `pass
  SILFunctionTransform "EarlyPerfInliner" on SILFunction
  "@$s7BleatUI10RemoteListCfD"`, which is that class's *synthesized*
  deallocating destructor. Writing the destructor out, even empty, avoids
  whatever shape the inliner chokes on; the members are released exactly as
  before, so nothing changes at runtime.
  - **It is invisible to the ordinary loop.** `swift build`, `swift test` and
    every debug run on a device pass with it removed; only `-O` fails, so the
    first thing it breaks is the archive — the last step before TestFlight and
    the slowest place to find out. `ci_scripts/ci_post_clone.sh` now runs
    `swift build -c release --target BleatUI` for exactly this, four seconds.
  - Not caused by the previews work: verified on `main` at `5bdf5ae`, same pass
    and same symbol. `@Observable` is not the trigger either — removing it still
    crashes. `RemoteList` is the module's only *generic* class, which is the
    obvious suspect, but a standalone package reproducing its shape (generic
    `@Observable final class`, a generic enum payload, an optional class
    reference, a `@Sendable` async closure, the same `load` body) compiles
    clean, so the trigger needs the whole module and is not characterised
    further.
  - **Swift 6.4 builds it without the `deinit`** (re-tested 3 Oct 2026,
    Xcode 27.1: `swift build -c release --target BleatUI` succeeds with it
    removed). It stays until an archive has been made without it, since an
    empty destructor costs nothing and the archive is where this was found;
    the release build in `ci_post_clone.sh` stays either way.

- **`SWIFT_APPROACHABLE_CONCURRENCY` is off on both sides, deliberately.** Its
  package half, `NonisolatedNonsendingByDefault`, reproducibly segfaults the
  test bundle on Swift 6.3.3: `swift test` dies with signal 11, while
  `swift test --no-parallel` passes all 70 and every suite passes alone — so it
  only bites under swift-testing's parallel execution. Enabling it for the app
  alone would be worse than leaving it off for both, because then the seam
  really would differ.
  - **Swift 6.4 no longer crashes** (re-tested 3 Oct 2026, Xcode 27.1): with
    the feature on, three parallel `swift test` runs passed all 485 tests. So
    it is off now by choice, not because it cannot be on. Turning it on is
    its own change: every `nonisolated async` function then runs on its
    caller's actor, so anything heavy that `BleatUI` reaches that way —
    decoding a reply, parsing a transcript — has to be marked `@concurrent`
    first or it moves onto the main actor.
- **`.defaultIsolation(MainActor.self)` is on `BleatUI` only.** `BleatKit` is a
  transport and domain library whose work belongs off the main actor, and the
  console tool links it with no main actor in sight. Isolation there is
  expressed per type.
- `SWIFT_VERSION` is the setting that silently lags: the isolation settings can
  be on while strict checking is not actually running. Check it before believing
  the project is on Swift 6.
