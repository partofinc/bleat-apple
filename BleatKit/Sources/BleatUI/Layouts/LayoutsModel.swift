import BleatKit
import Observation

/// A Mac's saved `herdr-layout` layouts, and restoring, saving and closing
/// them from the phone.
///
/// **On the list's own connection** (`TerminalsModel.shell()`), never a dial
/// of its own: the same rule as the new-terminal sheet, for the same reason.
///
/// **Found by asking.** There is no separate check for the script: the list
/// is asked for whenever the host's terminal list goes live, and a shell that
/// says "not found" is a host without layouts. Anything else that fails
/// leaves what was known as it was, so a dropped connection does not take
/// the Layouts button away.
///
/// **An action outlives the sheet.** It runs in a task of its own, not the
/// sheet's: closing the sheet, or the phone leaving the host's screen, does
/// not cancel a restore half way. On the host the script is shielded from
/// the phone going away too (`HerdrLayoutCommand.script`).
@Observable
final class LayoutsModel {
    enum Availability: Equatable {
        case unknown, available, absent
    }

    enum Action: Equatable {
        case restore, update, close, closeAnyway
        case rename(to: String)

        func command(for name: String) -> HerdrLayoutCommand {
            switch self {
            case .restore: .restore(name)
            case .update: .update(name)
            case .close: .close(name, force: false)
            case .closeAnyway: .close(name, force: true)
            case .rename(let new): .rename(name, to: new)
            }
        }

        /// What the row says while it runs.
        var progress: String {
            switch self {
            case .restore: "Restoring…"
            case .update: "Saving…"
            case .close, .closeAnyway: "Closing…"
            case .rename: "Renaming…"
            }
        }
    }

    /// What the last action came to, for the top of the sheet.
    struct Outcome: Equatable {
        let message: String
        let failed: Bool
    }

    private(set) var availability: Availability = .unknown
    private(set) var layouts: [HerdrLayout] = []
    /// Whether a read is in flight.
    var isLoading: Bool { loadsInFlight > 0 }
    /// Reads can overlap (from review): one as the list goes live, one as
    /// the sheet opens, one after an action. Counted, so the first to end
    /// does not hide the spinner of another, and numbered, so only the
    /// latest one's answer is kept.
    private var loadsInFlight = 0
    private var loadGeneration = 0
    /// Why the list could not be read just now.
    private(set) var loadProblem: String?
    /// The layout an action is running on, and which.
    private(set) var running: (name: String, action: Action)?
    private(set) var outcome: Outcome?
    /// A layout whose close was refused because its agents are working:
    /// the sheet offers to close it anyway.
    var stillWorking: String?

    let hostName: String
    private let hcPath: String?
    private let shell: () async throws -> any ShellRunner

    init(hostName: String, hcPath: String?, shell: @escaping () async throws -> any ShellRunner) {
        self.hostName = hostName
        self.hcPath = hcPath
        self.shell = shell
    }

    /// Reads the list.
    ///
    /// **The script is there whenever it ran** (from review): a list it
    /// failed to give, Herdr.app not running or output that does not read,
    /// still shows the button, and the sheet says why. Only a failure to
    /// reach the host leaves that unknown.
    func load() async {
        loadGeneration += 1
        let generation = loadGeneration
        loadsInFlight += 1
        defer { loadsInFlight -= 1 }
        let result: Result<[HerdrLayout], any Error>
        do {
            let output = try await shell().run(shell: HerdrLayoutCommand.list.command(hcPath: hcPath))
            result = .success(try HerdrLayout.list(inOutput: output))
        } catch {
            result = .failure(error)
        }
        guard generation == loadGeneration else { return }
        switch result {
        case .success(let read):
            layouts = read
            availability = .available
            loadProblem = nil
        case .failure(is CancellationError):
            return
        case .failure(let error) where HerdrLayoutCommand.isMissing(error):
            availability = .absent
            layouts = []
            loadProblem = nil
        case .failure(let error):
            if error is ShellError || error is DecodingError { availability = .available }
            loadProblem = Self.message(for: error)
        }
    }

    /// Starts `action` on the layout called `name`, unless one is running.
    /// The list is read again once it has finished.
    @discardableResult
    func perform(_ action: Action, on name: String) -> Task<Void, Never>? {
        guard running == nil else { return nil }
        running = (name, action)
        outcome = nil
        return Task {
            do {
                let output = try await shell().run(shell: action.command(for: name).command(hcPath: hcPath))
                outcome = Outcome(message: HerdrLayoutCommand.summary(inOutput: output) ?? "Done.", failed: false)
            } catch let error where action == .close && HerdrLayoutCommand.isStillWorking(error) {
                stillWorking = name
            } catch {
                outcome = Outcome(message: Self.message(for: error), failed: true)
            }
            // Done before the list is read again (from review): the alert
            // offering Close Anyway is up during that read, and its tap
            // was turned away as a second action.
            running = nil
            await load()
        }
    }

    /// The script's own words where it said no.
    static func message(for error: any Error) -> String {
        if let error = error as? ShellError {
            let refusal = HerdrLayoutCommand.refusal(in: error)
            if !refusal.isEmpty { return refusal }
        }
        return ErrorMessage.of(error)
    }
}
