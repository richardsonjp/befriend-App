import Foundation
import Testing
@testable import PetCore

struct ChatCommandTests {
    @Test func parsesCommandsAndTheirText() throws {
        let (command, argument) = try #require(ChatCommand.parse("/csv the budget items "))
        #expect(command.name == "csv" && command.action == .file(.csv) && argument == "the budget items")
        #expect(ChatCommand.parse("/Standup")?.command.name == "standup")
        #expect(ChatCommand.parse("/nope hi") == nil && ChatCommand.parse("hello /csv") == nil)
    }

    @Test func slashListsEverythingThenFilters() {
        #expect(ChatCommand.suggestions(for: "/")?.count == ChatCommand.all.count)
        #expect(ChatCommand.suggestions(for: "/s")?.map(\.name) == ["summarize", "standup", "schedule", "shorten"])
        #expect(ChatCommand.suggestions(for: "/csv the") == nil && ChatCommand.suggestions(for: "hi") == nil)
    }

    @Test func namesAreUniqueAndHelpCoversThem() {
        #expect(Set(ChatCommand.all.map(\.name)).count == ChatCommand.all.count)
        #expect(ChatCommand.all.allSatisfy { ChatCommand.helpText.contains("/\($0.name)") })
    }

    @Test func naturalFileRequests() {
        #expect(FileIntent.detect("Can you make a CSV of the budget?") == .csv)
        #expect(FileIntent.detect("export this as a PDF please") == .pdf)
        #expect(FileIntent.detect("turn these notes into JSON") == .json)
        #expect(FileIntent.detect("create calendar events for the launch week") == .ics)
        #expect(FileIntent.detect("add it to my calendar") == .ics)
        #expect(FileIntent.detect("save the summary as markdown") == .md)
        #expect(FileIntent.detect("buat file pdf dari catatan ini") == nil || FileIntent.detect("buat file pdf dari catatan ini") == .pdf)
    }

    @Test func mentionsAreNotRequests() {
        #expect(FileIntent.detect("Read this PDF and write a summary") == nil)
        #expect(FileIntent.detect("what's in the CSV I attached?") == nil)
        #expect(FileIntent.detect("how do I open a json file in excel") == nil)
    }
}
