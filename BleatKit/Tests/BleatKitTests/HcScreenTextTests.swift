import Foundation
import Testing
@testable import BleatKit

@Suite("A terminal's screen as text")
struct HcScreenTextTests {
    @Test("the last lines with something on them, trailing spaces and blank tail dropped")
    func lastLines() {
        let screen = HcScreenText(text: "one   \n\ntwo\nthree  \n\n   \n")
        #expect(screen.lastLines(3) == ["", "two", "three"])
        #expect(screen.lastLines(10) == ["one", "", "two", "three"])
        #expect(HcScreenText(text: "\n \n").lastLines(3).isEmpty)
    }

    @Test("a reply without text is contract drift")
    func noText() {
        #expect(throws: DecodingError.self) { try HcScreenText(reply: .object([:])) }
    }
}
