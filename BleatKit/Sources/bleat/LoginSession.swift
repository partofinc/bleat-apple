#if os(macOS)   // see main.swift: the console tool is macOS-only
import BleatKit
import BleatProcess
import Foundation

/// `bleat login-session` — keep a herdr session in the desktop login session,
/// so agents in it can sign in.
///
/// The fix for the thing `SecuritySession` diagnoses: a session started over SSH
/// puts its server, and therefore every pane and agent it will ever spawn, in an
/// audit session where the login keychain is unreadable, and nothing can move a
/// running process out of it. A launchd agent in `gui/<uid>` starts in the Aqua
/// session instead. See `LoginSessionAgent` for why the phone cannot install
/// this itself.
///
/// Deliberately local-only, like `bleat keys`: it installs something that runs
/// at every login.
enum LoginSession {
    static func run(options: Options) async throws {
        guard let subcommand = options.positional.first else {
            throw ToolFailure("login-session needs a subcommand: install <name>, remove <name>, or list")
        }
        let rest = Array(options.positional.dropFirst())

        switch subcommand {
        case "install":
            guard rest.count == 1 else {
                throw ToolFailure("install takes exactly one session name")
            }
            try await install(rest[0], options: options)
        case "remove":
            guard rest.count == 1 else {
                throw ToolFailure("remove takes exactly one session name")
            }
            try remove(rest[0])
        case "list":
            guard rest.isEmpty else {
                throw ToolFailure("unexpected argument(s): \(rest.joined(separator: " "))")
            }
            try list()
        default:
            throw ToolFailure(
                "unknown login-session subcommand '\(subcommand)': expected install, remove or list"
            )
        }
    }

    // MARK: - install

    static func install(_ name: String, options: Options) async throws {
        let session = try validated(name)
        let herdrPath = try resolveHerdr(options.herdrPath)
        let agent = LoginSessionAgent(session: session, herdrPath: herdrPath)
        let uid = Int(getuid())

        // **Looked at before anything is written**, the rule `SessionStarter`
        // follows: `session attach` is idempotent — measured, same pid and no
        // error against a running session — so if this one is already up, the
        // job we are about to load will start nothing and its panes will stay
        // in whatever audit session they are in now. Without this look, the
        // install would report success over a session it had not moved.
        let wasRunning = try await isRunning(session, herdrPath: herdrPath)

        let url = agent.plistURL(home: FileManager.default.homeDirectoryForCurrentUser)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try agent.plistData().write(to: url, options: .atomic)
        print("Installed \(url.path)")

        // Unloaded first so a reinstall replaces the job rather than colliding
        // with it. A `bootout` for something that is not loaded fails, and that
        // is not an error here — the same reason `AuthorizedKeys.removeCommand`
        // ends in `|| true`.
        _ = launchctl(["bootout", agent.serviceTarget(uid: uid)])

        let bootstrap = launchctl([
            "bootstrap", LoginSessionAgent.domainTarget(uid: uid), url.path,
        ])
        guard bootstrap.status == 0 else {
            throw ToolFailure("""
                launchd would not load it: \(bootstrap.message)
                The file is written, so it will be loaded at the next login.
                """)
        }

        // Checked, not assumed: `bootstrap` exiting 0 is not the same as the
        // service being there.
        guard launchctl(["print", agent.serviceTarget(uid: uid)]).status == 0 else {
            throw ToolFailure("launchd loaded it without complaint but does not list \(agent.label)")
        }
        print("Loaded \(agent.label) into \(LoginSessionAgent.domainTarget(uid: uid))")

        try await report(agent, uid: uid, wasRunning: wasRunning)
    }

    /// Whether the session came up, and whether its panes are where they need
    /// to be.
    ///
    /// **The install is only worth as much as this check.** Everything above it
    /// proves launchd accepted a job; only this says an agent started in that
    /// session will be able to read the keychain, and it is measured the same
    /// way the app measures it — `pane process-info` for a pane's shell, then
    /// its audit session against the login one.
    private static func report(
        _ agent: LoginSessionAgent, uid: Int, wasRunning: Bool
    ) async throws {
        guard try await waitForSession(agent) else {
            throw ToolFailure("""
                \(agent.session.text) is not running, so launchd's job did not bring it up.
                Look for it with: launchctl print \(agent.serviceTarget(uid: uid))
                """)
        }

        switch try await keychainReach(of: agent) {
        case .sharedWithLogin:
            print("""

                Done. \(agent.session.text) is running in the desktop login session, so agents \
                started in it can read the login keychain.
                It will come back there at every login. Attach from the phone rather than \
                starting it — a session the phone starts is in a different audit session again.
                """)
        case .detached where wasRunning:
            // The measured case, and the one worth the whole look-before-write:
            // `attach` found the session already up and did nothing.
            print("""

                Installed, but \(agent.session.text) was already running and `session attach` is \
                idempotent — so nothing restarted it, and its panes are still in the audit \
                session they were started from. Agents in it still cannot reach the keychain.

                It will be correct after the next login. To fix it now, stop the session and \
                install again:
                    herdr session stop \(agent.session.text)
                    bleat login-session install \(agent.session.text)
                **`herdr session stop` ends every process in the session**, agents included.
                """)
        case .detached:
            print("""

                Installed and running, but its panes are **not** in the desktop login session, \
                which is what this command exists to arrange. Agents in it will not be able to \
                sign in. Worth reporting: nothing measured so far explains it.
                """)
        case .unknown:
            print("""

                Installed and running. Could not confirm which audit session its panes are in, \
                so this says nothing either way — `launchctl` or `pane process-info` did not \
                answer.
                """)
        }
    }

    // MARK: - remove

    static func remove(_ name: String) throws {
        let session = try validated(name)
        let agent = LoginSessionAgent(session: session, herdrPath: "/unused")
        let uid = Int(getuid())
        let url = agent.plistURL(home: FileManager.default.homeDirectoryForCurrentUser)

        guard FileManager.default.fileExists(atPath: url.path) else {
            throw ToolFailure("""
                nothing installed for '\(session.text)'.
                Run `bleat login-session list` to see what is.
                """)
        }

        _ = launchctl(["bootout", agent.serviceTarget(uid: uid)])
        try FileManager.default.removeItem(at: url)

        // The same shape as a revocation: the removal is read back, because a
        // delete that quietly did nothing would otherwise be reported as done.
        guard !FileManager.default.fileExists(atPath: url.path) else {
            throw ToolFailure("\(url.path) is still there")
        }
        print("""
            Removed \(url.path)

            **The session itself is untouched and still running.** Stopping it would end every \
            process in it, which is not what removing a launchd job asks for. Stop it yourself \
            when you want to:
                herdr session stop \(session.text)
            """)
    }

    // MARK: - list

    static func list() throws {
        let directory = LoginSessionAgent.launchAgentsDirectory(
            home: FileManager.default.homeDirectoryForCurrentUser
        )
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        let sessions = LoginSessionAgent.installedSessions(inLaunchAgents: names)

        guard !sessions.isEmpty else {
            print("""
                No sessions are kept in the login session on this machine.

                Install one so agents started in it from a phone can sign in:
                    bleat login-session install <name>
                """)
            return
        }

        let uid = Int(getuid())
        for name in sessions {
            guard let session = SessionName(name) else { continue }
            let agent = LoginSessionAgent(session: session, herdrPath: "/unused")
            let loaded = launchctl(["print", agent.serviceTarget(uid: uid)]).status == 0
            print("\(name)  \(loaded ? "loaded" : "installed, not loaded")")
        }
    }

    // MARK: - Asking the host

    private static func validated(_ name: String) throws -> SessionName {
        guard let session = SessionName(name) else {
            throw ToolFailure(
                SessionName.problem(with: name)?.message ?? "'\(name)' is not a usable session name"
            )
        }
        return session
    }

    /// **Resolved before anything is written**, the rule `Enrollment` follows: a
    /// machine without herdr is refused with nothing to undo.
    private static func resolveHerdr(_ override: String?) throws -> String {
        if let override {
            guard FileManager.default.isExecutableFile(atPath: override) else {
                throw ToolFailure("no executable at \(override)")
            }
            return override
        }
        // `command -v` exits 1 when it finds nothing and the login shell exits
        // with it, hence the `|| true` inside `HerdrLookup.command`; and the
        // answer is read as a line within stdout because a login shell sources
        // the profile and profiles print banners.
        let answer = try Shell.output(HerdrLookup.command)
        guard let path = HerdrLookup.path(inOutput: answer) else {
            throw ToolFailure("""
                could not find herdr on this machine.
                Pass it explicitly: bleat login-session install <name> --herdr /path/to/herdr
                """)
        }
        return path
    }

    private static func client(_ agent: LoginSessionAgent) -> HerdrClient {
        HerdrClient(transport: LocalProcessTransport(
            executable: URL(fileURLWithPath: agent.herdrPath), session: agent.session.text
        ))
    }

    private static func isRunning(_ session: SessionName, herdrPath: String) async throws -> Bool {
        let client = HerdrClient(
            transport: LocalProcessTransport(executable: URL(fileURLWithPath: herdrPath))
        )
        return try await client.sessions().contains { $0.name == session.text && $0.running }
    }

    /// Polled rather than assumed, for the reason `SessionStarter` polls:
    /// launchd returning promptly says nothing about herdr being up yet.
    private static func waitForSession(_ agent: LoginSessionAgent) async throws -> Bool {
        for _ in 0..<20 {
            if try await isRunning(agent.session, herdrPath: agent.herdrPath) { return true }
            try? await Task.sleep(for: .milliseconds(500))
        }
        return false
    }

    /// The same measurement the app makes, through the same type.
    private static func keychainReach(
        of agent: LoginSessionAgent
    ) async throws -> SecuritySession.Reach {
        let client = client(agent)
        guard let pane = try await client.panes().first?.paneID,
              let pid = try await client.paneProcessInfo(target: pane).shellPID,
              let command = SecuritySession.command(paneShellPid: pid)
        else { return .unknown }
        return SecuritySession(inOutput: try Shell.output(command)).reach
    }

    /// `launchctl` by argv rather than through a shell: every argument here is a
    /// path or a domain target built from a validated session name, and there is
    /// nothing to gain by handing them to `sh` to re-split.
    ///
    /// Returns the status rather than throwing, because two callers need to
    /// tolerate a failure — `bootout` for a job that is not loaded, and `print`
    /// used as a question.
    private static func launchctl(_ arguments: [String]) -> (status: Int32, message: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = arguments
        let output = Pipe()
        process.standardOutput = FileHandle.nullDevice
        process.standardError = output
        process.standardInput = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return (-1, "could not run launchctl: \(error.localizedDescription)")
        }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let message = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return (
            process.terminationStatus,
            message.isEmpty ? "exit \(process.terminationStatus)" : message
        )
    }
}
#endif
