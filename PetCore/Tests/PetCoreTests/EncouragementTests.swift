import Foundation
import Testing
@testable import PetCore

struct EncouragementTests {
    @Test func saidLinesIgnoreCaseAndPunctuation() {
        let said = SaidLines().adding("You've got this!")
        #expect(said.contains("you've got THIS"))
        #expect(!said.contains("You've got this, Jo!"))
        #expect(said.adding("YOU'VE GOT THIS.").lines == ["You've got this!"])
    }

    @Test func saidLinesKeepTheLatest() {
        let said = (0..<(SaidLines.limit + 5)).reduce(SaidLines()) { $0.adding("Line \($1)") }
        #expect(said.lines.count == SaidLines.limit)
        #expect(said.lines.last == "Line \(SaidLines.limit + 4)")
        #expect(said.promptLine?.components(separatedBy: "\n").count == SaidLines.promptCount + 1)
        #expect(SaidLines().promptLine == nil)
    }

    @Test func cannedEncouragementAvoidsWhatWasSaid() {
        let said = SaidLines(lines: Array(PetReaction.cannedEncouragements.dropLast()))
        #expect(PetReaction.encouragement(avoiding: said).dialogue == PetReaction.cannedEncouragements.last)
        // All used up: any canned line rather than none.
        let all = SaidLines(lines: PetReaction.cannedEncouragements)
        #expect(PetReaction.cannedEncouragements.contains(PetReaction.encouragement(avoiding: all).dialogue))
    }

    @MainActor @Test func batchNeverRepeatsAndIsRemembered() async throws {
        let defaults = try #require(UserDefaults(suiteName: "EncouragementTests"))
        defaults.removePersistentDomain(forName: "EncouragementTests")
        let brain = PetBrain(forceFallback: true, saidStore: defaults)
        let lines = await brain.encouragements(6).map(\.dialogue)
        #expect(Set(lines).count == 6)
        #expect(SaidLines.load(from: defaults).lines == lines)
        // A new brain (new personality version) still knows what was said.
        let next = await PetBrain(forceFallback: true, saidStore: defaults).encouragements(1)[0].dialogue
        #expect(!lines.contains(next))
    }

    @Test func encourageStaysOnDevice() {
        #expect(Trigger.encourage.kind.staysOnDevice)
        #expect(Trigger.encourage.wantsFreshLine && Trigger.pomodoro(.focusEnded).wantsFreshLine)
        #expect(!Trigger.poked.wantsFreshLine)
    }
}
