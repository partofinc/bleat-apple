/// What `session stop --json` and `session delete --json` answer with.
///
/// One type for both, because the two replies differ only in which flag they
/// carry — captured live from herdr 0.9.0 into `Fixtures/session-stop.json` and
/// `Fixtures/session-delete.json`:
///
/// ```
/// {"session":{…},"stopped":true}
/// {"deleted":true,"session":{…}}
/// ```
///
/// Client-side commands, like `session list`: they need an explicit `--json`
/// and their payload has no `{"id","result"}` envelope.
///
/// **Neither flag is proof, and `deleted` is actively misleading.** Measured:
/// `herdr session delete nosuchsession --json` answers `{"deleted":true,…}`
/// and exits 0, having deleted nothing — it does not even create the directory
/// it claims to have removed. So a caller that reads `deleted` as "it is gone"
/// will report a success over a session that is still there under a name it
/// misspelled. The same class of lie as `bleat keys revoke`'s removal exiting 0
/// when it matched nothing, and it takes the same answer: read the list back.
///
/// `stopped` is honest by comparison — stopping something not running exits 1
/// with `session_stop_failed` — but it is checked the same way rather than
/// trusted, because there is no way to tell the two apart from the shape alone.
public struct SessionChange: Codable, Sendable, Hashable {
    /// The session as the host saw it, after the change.
    public let session: SessionInfo
    /// Present on a `stop` reply.
    public let stopped: Bool?
    /// Present on a `delete` reply. See above: not evidence.
    public let deleted: Bool?

    public init(session: SessionInfo, stopped: Bool? = nil, deleted: Bool? = nil) {
        self.session = session
        self.stopped = stopped
        self.deleted = deleted
    }
}
