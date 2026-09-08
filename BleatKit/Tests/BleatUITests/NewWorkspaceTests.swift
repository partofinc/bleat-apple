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
        let model = NewWorkspaceModel(previewing: "/Users/ravil/Developer")
        #expect(model.pathProblem == nil)
        #expect(model.canCreate)
    }

    /// herdr's own default for an omitted `--label`, so the placeholder is not
    /// lying about what leaving the field blank will do.
    @Test("the label placeholder is the folder's name")
    func placeholderIsTheBasename() {
        #expect(NewWorkspaceModel(previewing: "/Users/ravil/Developer/rawillk/bleat-apple")
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
            previewing: "/Users/ravil/Developr",
            failure: "There is no directory at /Users/ravil/Developr on this host."
        )
        #expect(model.failure != nil)
        model.clearFailure()
        #expect(model.failure == nil)
    }

    /// **The button is spent once something exists.** `misplaced` means a
    /// workspace was created, just not where it was asked to go — so the screen
    /// still has something to say, but tapping Create again would make a second
    /// one on someone's Mac.
    @Test("a workspace that landed elsewhere disarms the button rather than inviting a retry")
    func createdElsewhereDisarms() {
        let model = NewWorkspaceModel(
            previewing: "/Users/ravil/Developer",
            misplaced: "Created Developer, but its pane opened in /Users/ravil rather than "
                + "/Users/ravil/Developer."
        )
        #expect(model.directory != nil, "the path itself is fine; it is the outcome that is not")
        #expect(!model.canCreate)
    }

    /// The `#Preview` seam, the same promise `RemoteList(previewing:)` makes —
    /// and it matters as much here as for `NewSessionModel`, because this one
    /// writes. A canvas that dialled would make a workspace on the dev Mac.
    @Test("a parked model creates nothing")
    func parkedCreatesNothing() async {
        let model = NewWorkspaceModel(previewing: "/Users/ravil/Developer")
        #expect(await model.create(on: .preview) == .failed)
        #expect(model.failure == nil, "a parked create reported a failure, so it tried")
        #expect(model.misplaced == nil)
        #expect(!model.isCreating)
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
