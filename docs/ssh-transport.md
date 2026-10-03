# SSH transport (Phase 1 decisions)

> Moved verbatim from `CLAUDE.md` on 1 Oct 2026. Where the text says "this file", "above" or "below", it means the old single file; a **bold** section name can be found with `grep -r docs/`.

- Library: **Citadel** (SwiftNIO SSH). Approved dependency. Do not add others
  without asking. Pulls in swift-nio, swift-crypto, swift-asn1, BigInt.
- **Citadel forces macOS 15 / iOS 18.** Every stdin-capable API (`withExec`,
  `withPTY`, `withTTY`) is `@available(macOS 15.0, *)`; only the read-only
  `executeCommandStream` works below that. The package platforms were raised
  to match; they are 26 now, well above it.
- Auth: ed25519 key, parsed with `Curve25519.Signing.PrivateKey(sshEd25519:)`.
  Stored in Keychain (Phase 2) or a file under `~/.bleat/` for the console tool.
- Host key: trust-on-first-use, pinned per `host:port` in `~/.bleat/known_hosts`
  as the OpenSSH `algorithm base64` string. A changed key is a hard error and
  never overwrites the pin; an intentional rekey means deleting the line.
- **Session selection is a command prefix, not channel env.** Citadel can send
  env requests, but they need `PermitUserEnvironment` in sshd, which is off by
  default. sshd runs an exec command through the login shell, so
  `env -u HERDR_SOCKET_PATH HERDR_SESSION=x herdr …` works everywhere. Every
  argument is single-quoted.
- **`herdr` is usually not on the PATH of a non-login shell** — verified: an
  exec channel gets `env: herdr: No such file or directory`. Saved hosts carry
  an absolute `herdrPath`.
- **A clean detach looks like an error at the Citadel layer.** After
  `terminal.release` the remote exits and the channel is gone, so the scoped
  `withExec` teardown throws `Already closed`. `SSHStream` tracks whether
  stdout drained normally first and finishes cleanly when it did — without
  that, every detach reports a spurious failure.
- Citadel is not `Sendable`-audited, so `SSHClient` cannot live in an actor.
  `SSHTransport` is a lock-guarded `final class` and `UnsafeTransfer` is the
  single, documented escape hatch in the package.
- The console tool takes `user@host[:port]` plus `--key PATH`; nothing is read
  from `~/.ssh/config` in Phase 1. Bare IPv6 (`user@fe80::1`) is accepted;
  brackets are required to add a port (`user@[fe80::1]:2222`).
