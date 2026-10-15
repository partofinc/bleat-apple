import BleatKit
import Testing
@testable import BleatUI

/// The form that makes a workspace, above the transport.
///
/// `WorkspaceCreateTests` covers what is sent and what the reply means; this
/// covers what the screen decides before anything is sent — which is most of
/// the value here, because herdr accepts a directory that does not exist and
/// says nothing about it.
@Suite("Naming a new workspace")
@MainActor
struct NewWorkspaceTests {

    @Test("an empty field is the resting state, not an error")
    func emptyIsQuiet() {
        let model = NewWorkspaceModel(previewing: "")
        #expect(model.pathProblem == nil, "an untouched field was already complaining")
        #expect(!model.canCreate)
    }

    /// The silent one: herdr resolves a relative path against its own server
    /// process's working directory, which from a phone is unknowable.
    @Test("a relative path is refused, with the reason")
    func relativePathIsExplained() {
        let model = NewWorkspaceModel(previewing: "Developer/bleat-apple")
        #expect(model.pathProblem != nil)
        #expect(!model.canCreate)
    }

    @Test("an absolute path arms the button")
    func absolutePathIsAllowed() {
        let model = NewWorkspaceModel(previewing: "/Users/robin/Developer")
        #expect(model.pathProblem == nil)
        #expect(model.canCreate)
    }

    /// herdr's own default for an omitted `--label`, so the placeholder is not
    /// lying about what leaving the field blank will do.
    @Test("the label placeholder is the folder's name")
    func placeholderIsTheBasename() {
        #expect(NewWorkspaceModel(previewing: "/Users/robin/Developer/partofinc/bleat-apple")
            .labelPlaceholder == "bleat-apple")
    }

    /// Nothing to name a workspace after yet, and no path to derive one from.
    @Test("an unusable path suggests no label")
    func placeholderFallsBack() {
        #expect(NewWorkspaceModel(previewing: "").labelPlaceholder == "Label")
    }

    /// A failure is about the attempt that produced it. Left standing while the
    /// user edits the path, it reads as a verdict on the new one.
    @Test("editing the path is not still an error")
    func failureIsClearable() {
        let model = NewWorkspaceModel(
            previewing: "/Users/robin/Developr",
            failure: "There is no directory at /Users/robin/Developr on this host."
        )
        #expect(model.failure != nil)
        model.clearFailure()
        #expect(model.failure == nil)
    }

    /// **The button is spent once something may exist.** A `warning` means
    /// either a workspace was created somewhere else, or the connection dropped
    /// in the window where it may or may not have been created — and in both
    /// cases tapping Create again risks a second one on someone's Mac.
    @Test("a warning disarms the button rather than inviting a retry")
    func aWarningDisarms() {
        let model = NewWorkspaceModel(
            previewing: "/Users/robin/Developer",
            warning: "Created Developer, but its pane opened in /Users/robin rather than "
                + "/Users/robin/Developer."
        )
        #expect(model.directory != nil, "the path itself is fine; it is the outcome that is not")
        #expect(!model.canCreate)
    }

    /// **The bug this pairing shipped with, before review.** The model is
    /// `@State` on `WorkspacesView`, not on the sheet, so everything it holds
    /// outlives a dismissal. `clearFailure` was the only reset and it does not
    /// touch `warning` — so one "landed elsewhere" left the button reading
    /// "Done" forever, over a stale message about a workspace made minutes
    /// earlier, with nothing on the screen able to clear it. Popping the whole
    /// session screen was the only way out.
    @Test("editing the path does not clear a warning, but reopening the sheet does")
    func onlyResetClearsAWarning() {
        let model = NewWorkspaceModel(
            previewing: "/Users/robin/Developer",
            label: "Developer",
            failure: "something went wrong",
            warning: "Created Developer, but its pane opened in /Users/robin."
        )
        // Editing is not undoing: something may be on the host.
        model.clearFailure()
        #expect(model.failure == nil)
        #expect(model.warning != nil, "a text edit cleared a warning about a real workspace")
        #expect(!model.canCreate)

        // Reopening is.
        model.reset()
        #expect(model.warning == nil)
        #expect(model.failure == nil)
        // And the path goes too, or a reopened sheet is prefilled *and* armed —
        // where one reflexive tap makes a second workspace at the same path.
        #expect(model.path.isEmpty)
        #expect(model.label.isEmpty)
        #expect(!model.canCreate, "an empty form is not something to submit")
    }

    /// The `#Preview` seam, the same promise `RemoteList(previewing:)` makes —
    /// and it matters as much here as for `NewSessionModel`, because this one
    /// writes. A canvas that dialled would make a workspace on the dev Mac.
    @Test("a parked model creates nothing")
    func parkedCreatesNothing() async {
        let model = NewWorkspaceModel(previewing: "/Users/robin/Developer")
        #expect(await model.create(on: .preview) == .failed)
        #expect(model.failure == nil, "a parked create reported a failure, so it tried")
        #expect(model.warning == nil)
        #expect(!model.isCreating)
    }

    /// A path pasted from a terminal's `pwd` carries a newline. Kept, it passes
    /// every check here and then fails on the host — and the message names the
    /// directory *without* the newline, so the user is told there is no such
    /// directory about one that plainly exists.
    @Test("a path pasted with a trailing newline is still a path")
    func tolerantOfAPastedNewline() {
        let model = NewWorkspaceModel(previewing: "/Users/robin/Developer\n")
        #expect(model.pathProblem == nil)
        #expect(model.canCreate)
        #expect(model.directory?.path == "/Users/robin/Developer")
    }

    /// A field holding nothing but a pasted newline is still an untouched
    /// field. With `.whitespaces` on the guard — which excludes newlines — it
    /// fell through to `WorkspaceDirectory`, which reported `.empty`, so "Give
    /// the workspace a directory." appeared in red under what looks blank.
    @Test("a field holding only whitespace is still the resting state")
    func whitespaceIsStillEmpty() {
        for path in ["\n", "   ", " \n "] {
            #expect(NewWorkspaceModel(previewing: path).pathProblem == nil,
                    "a blank-looking field complained")
        }
    }

    /// **A label of spaces is not an empty label.** `createWorkspace` omits the
    /// flag only for an exactly empty string, so `"   "` would be sent as
    /// `--label '   '` and the workspace created with a blank-looking name
    /// instead of the basename the placeholder promised.
    @Test("a label of nothing but spaces falls back to the folder's name")
    func blankLabelIsNoLabel() {
        let model = NewWorkspaceModel(previewing: "/Users/robin/Developer", label: "   ")
        #expect(model.trimmedLabel.isEmpty)
        #expect(model.labelPlaceholder == "Developer")
    }

    /// And the same string is what the duplicate hint compares, or a trailing
    /// space typed after an existing name suppresses a warning about a name
    /// herdr will render identically.
    @Test("a trailing space does not hide a duplicate")
    func trimsBeforeComparing() {
        #expect(NewWorkspaceModel(previewing: "/x", label: "forge ").trimmedLabel == "forge")
    }

    /// The suggestions are a convenience, so a host that cannot answer must
    /// leave a usable form rather than an error about a list nobody asked for.
    @Test("a parked model fetches no suggestions and does not complain")
    func parkedFetchesNothing() async {
        let model = NewWorkspaceModel(previewing: "")
        await model.loadSuggestions(for: .preview)
        #expect(model.suggestions.isEmpty)
        #expect(model.failure == nil)
    }
}
