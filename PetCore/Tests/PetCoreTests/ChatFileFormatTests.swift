import Foundation
import PDFKit
import Testing
@testable import PetCore

struct ChatFileFormatTests {
    @Test func csvQuotesWhatNeedsIt() {
        let table = ChatTable(columns: ["Item", "Cost", "Note"], rows: [["Coffee, beans", "12.50", "say \"hi\""], ["Tea", "3"]])
        let text = String(decoding: ChatFileWriter.csv(table), as: UTF8.self)
        #expect(text == "Item,Cost,Note\r\n\"Coffee, beans\",12.50,\"say \"\"hi\"\"\"\r\nTea,3,\r\n")
    }

    @Test func jsonHasRealTypes() throws {
        let table = ChatTable(columns: ["Name", "Age", "Is Member", "Phone", "Code"], rows: [["Mochi", "3", "yes", "+62 812", "007"]])
        let objects = try #require(try JSONSerialization.jsonObject(with: ChatFileWriter.json(table)) as? [[String: Any]])
        #expect(objects[0]["name"] as? String == "Mochi")
        #expect(objects[0]["age"] as? Int == 3)
        #expect(objects[0]["isMember"] as? Bool == true)
        #expect(objects[0]["phone"] as? String == "+62 812" && objects[0]["code"] as? String == "007")
        #expect(ChatFileWriter.uniqueKeys(["Date", "date", "!!"]) == ["date", "date2", "field3"])
    }

    @Test func icsFollowsTheRules() {
        let start = ISO8601DateFormatter().date(from: "2026-10-01T02:00:00Z")!
        let event = ChatEvent(title: "Launch; review, final", start: start, end: start.addingTimeInterval(3600), allDay: false,
                              location: "Room 1", notes: String(repeating: "Long notes ", count: 20))
        let text = String(decoding: ChatFileWriter.ics([event], calendarName: "Launch", now: start), as: UTF8.self)
        #expect(text.hasPrefix("BEGIN:VCALENDAR\r\nVERSION:2.0\r\n") && text.hasSuffix("END:VCALENDAR\r\n"))
        #expect(text.contains("DTSTART:20261001T020000Z\r\n") && text.contains("DTEND:20261001T030000Z\r\n"))
        #expect(text.contains("SUMMARY:Launch\\; review\\, final\r\n"))
        #expect(text.components(separatedBy: "\r\n").allSatisfy { $0.utf8.count <= 75 }, "lines are folded")
        #expect(text.components(separatedBy: "\r\n").contains { $0.hasPrefix(" ") }, "a folded line continues after a space")
    }

    @Test func allDayEventsUseDates() {
        let day = ISO8601DateFormatter().date(from: "2026-10-01T12:00:00Z")!
        let text = String(decoding: ChatFileWriter.ics([ChatEvent(title: "Off", start: day, end: day, allDay: true, location: nil, notes: nil)],
                                                       calendarName: "x"), as: UTF8.self)
        #expect(text.contains("DTSTART;VALUE=DATE:") && text.contains("DTEND;VALUE=DATE:"))
    }

    @Test func markdownIsTidied() {
        let raw = "Sure! Here's your document:\n\n# Launch plan\n\n\n\n- One\n- Two\n"
        #expect(String(decoding: ChatFileWriter.markdown(raw), as: UTF8.self) == "# Launch plan\n\n- One\n- Two\n")
        #expect(String(decoding: ChatFileWriter.markdown("```markdown\n# A\n```"), as: UTF8.self) == "# A\n")
        let plain = String(decoding: ChatFileWriter.text("# Plan\n\n**Bold** move\n\n- one"), as: UTF8.self)
        #expect(plain == "PLAN\n\nBold move\n\n- one\n")
    }

    @Test func pdfPagesCarryTheText() throws {
        let long = "# Report\n\n" + (1...120).map { "Paragraph \($0) about the launch budget and plan." }.joined(separator: "\n\n")
        let pdf = try #require(PDFDocument(data: ChatFileWriter.pdf(long, title: "Report")))
        #expect(pdf.pageCount > 1)
        #expect(pdf.string?.contains("Paragraph 120") == true && pdf.string?.contains("Report") == true)
    }
}

struct ChatFileMakerTests {
    @Test func pastDatesMeanNextYear() {
        let now = ISO8601DateFormatter().date(from: "2026-10-01T12:00:00Z")!
        #expect(ChatFileMaker.rolledForward("2026-05-03", now: now) == "2027-05-03")
        #expect(ChatFileMaker.rolledForward("2026-10-05", now: now) == "2026-10-05")
        #expect(ChatFileMaker.rolledForward("2025-01-01", now: now) == "2025-01-01", "a date years ago was meant")
    }

    @Test func datesAreWorkedOutBesideTheirWords() {
        let now = ISO8601DateFormatter().date(from: "2026-10-01T04:00:00Z")!
        let text = ChatFileMaker.annotateDates("The launch is on May 3rd at 10:00, and a press call next Monday.", now: now)
        #expect(text.contains("May 3rd at 10:00 [2027-05-03 10:00]"))
        #expect(text.contains("next Monday [2026-10-05]"))
        #expect(ChatFileMaker.annotateDates("No dates here.", now: now) == "No dates here.")
    }

    @Test func eventsParseLocalTimes() throws {
        let event = try #require(ChatFileMaker.event(title: "Call", date: "2026-10-05", start: "09:30", minutes: 30, location: "", notes: nil))
        #expect(Calendar.current.component(.hour, from: event.start) == 9 && event.end.timeIntervalSince(event.start) == 1800)
        #expect(event.location == nil && !event.allDay)
        #expect(ChatFileMaker.event(title: "Off", date: "2026-10-05", start: "", minutes: 60, location: nil, notes: nil)?.allDay == true)
        #expect(ChatFileMaker.event(title: "x", date: "soon", start: "", minutes: 60, location: nil, notes: nil) == nil)
    }

    @Test func fileNamesAreSafe() {
        #expect(ChatFileMaker.fileName("Budget: Q3/Q4 \"final\"", .csv) == "Budget Q3 Q4 final.csv")
        #expect(ChatFileMaker.fileName("", .md) == "befriend.md")
    }

    @Test func headingsGetRoom() {
        let raw = "# Brief\n## Budget\n* Venue\n* Catering\nNotes line\n- one"
        #expect(String(decoding: ChatFileWriter.markdown(raw), as: UTF8.self) == "# Brief\n\n## Budget\n\n* Venue\n* Catering\nNotes line\n\n- one\n")
    }
}

struct FileTitleTests {
    @Test func anyHeadingNamesTheFile() {
        #expect(ChatFileMaker.title(of: "## Antartech.co Website Research\n\ntext") == "Antartech.co Website Research")
        #expect(ChatFileMaker.title(of: "# Plan") == "Plan")
        #expect(ChatFileMaker.title(of: "no heading") == nil)
    }
}
