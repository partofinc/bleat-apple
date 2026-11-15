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

        func command(for name: String) -> HerdrLayoutCommand {
            switch self {
            case .restore: .restore(name)
            case .update: .update(name)
            case .close: .close(name, force: false)
            case .closeAnyway: .close(name, force: true)
            }
        }

        /// What the row says while it runs.
        var progress: String {
            switch self {
            case .restore: "Restoring…"
            case .update: "Saving…"
            case .close, .closeAnyway: "Closing…"
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
    private(set) var isLoading = false
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
    func load() async {
        isLoading = true
        defer { isLoading = false }
        do {
            let output = try await shell().run(shell: HerdrLayoutCommand.list.command(hcPath: hcPath))
            layouts = try HerdrLayout.list(inOutput: output)
            availability = .available
            loadProblem = nil
        } catch is CancellationError {
            return
        } catch let error where HerdrLayoutCommand.isMissing(error) {
            availability = .absent
            layouts = []
        } catch {
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
            defer { running = nil }
            do {
                let output = try await shell().run(shell: action.command(for: name).command(hcPath: hcPath))
                outcome = Outcome(message: HerdrLayoutCommand.summary(inOutput: output) ?? "Done.", failed: false)
            } catch let error where action == .close && HerdrLayoutCommand.isStillWorking(error) {
                stillWorking = name
            } catch {
                outcome = Outcome(message: Self.message(for: error), failed: true)
            }
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
