import Foundation
import Testing
@testable import PetCore

struct ExplainShortcutTests {
    typealias M = ExplainShortcut.Modifiers
    let t0 = Date(timeIntervalSince1970: 1_000)

    /// Feeds modifier states (or "key" for another key) a tenth of a second apart; returns whether any fired.
    func run(_ steps: [Any], target: M = [.command, .option]) -> Bool {
        var tap = ModifierTap(target: target)
        var fired = false
        for (index, step) in steps.enumerated() {
            if let mods = step as? M { fired = tap.modifiers(mods, at: t0 + Double(index) * 0.1) || fired } else { tap.otherInput() }
        }
        return fired
    }

    @Test func tapOfCommandOptionFires() {
        #expect(run([M.command, M([.command, .option]), M.option, M()]))
        #expect(run([M.option, M([.command, .option]), M()]), "either order, released together")
    }

    @Test func otherShortcutsWithTheModifiersDont() {
        #expect(!run([M.command, M([.command, .option]), "key", M()]), "⌘⌥Esc stays Force Quit")
        #expect(!run([M.command, M([.command, .option]), M([.command, .option, .shift]), M()]), "an extra modifier")
        #expect(!run([M.command, M()]), "only half of it")
        #expect(!run([M.command, "key", M([.command, .option]), M()]), "⌘C then adding ⌥")
    }

    @Test func aKeyBeforehandDoesntSpoilTheNextTap() {
        #expect(run(["key", M.command, M([.command, .option]), M()]))
    }

    @Test func holdingTooLongIsntATap() {
        var tap = ModifierTap(target: [.command, .option])
        _ = tap.modifiers([.command, .option], at: t0)
        let slow = tap.modifiers([], at: t0 + 2)
        _ = tap.modifiers([.command, .option], at: t0 + 3)
        let quick = tap.modifiers([], at: t0 + 3.3)
        #expect(!slow)
        #expect(quick, "the next quick tap still works")
    }

    @Test func shortcutsReadAndValidate() {
        #expect(ExplainShortcut.standard.display == "⌥⌘" && ExplainShortcut.standard.isValid)
        #expect(ExplainShortcut(modifiers: [.control, .shift], keyCode: 14, keyName: "E").display == "⌃⇧E")
        #expect(!ExplainShortcut(modifiers: [.command]).isValid, "a lone ⌘ tap")
        #expect(!ExplainShortcut(modifiers: [], keyCode: 14, keyName: "E").isValid, "a bare key")
        #expect(ExplainShortcut(modifiers: [.command], keyCode: 14, keyName: "E").isValid)
    }
}
