import AVFoundation
import CoreImage
import Foundation
import Testing
@testable import PetCore

struct TimelapseTitleTests {
    private static let wednesday = ISO8601DateFormatter().date(from: "2026-09-30T09:14:00Z")!

    @Test func dateIsDayMonthYear() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        let date = calendar.date(from: DateComponents(year: 2026, month: 10, day: 1, hour: 12))!
        #expect(TimelapseTitle.date(date) == "01-10-2026")
    }

    @Test func titlesAreTidied() {
        #expect(TimelapseTitle.clean("\"Productive Wednesday.\"") == "Productive Wednesday")
        #expect(TimelapseTitle.clean("#TGIF grind\nmore") == "TGIF grind")
        #expect(TimelapseTitle.clean("   ") == nil)
        #expect((TimelapseTitle.clean(String(repeating: "word ", count: 20))?.count ?? 99) <= TimelapseTitle.maxLength)
    }

    @Test func promptKnowsTheDayTimeAndFocus() {
        let context = TimelapseTitleContext(startedAt: Self.wednesday, plannedMinutes: 25, focusedMinutes: 12)
        #expect(context.promptLine.contains("Weekday: Wednesday"))
        #expect(context.promptLine.contains("stopped early after 12 of 25 minutes"))
        #expect(TimelapseTitleContext(startedAt: Self.wednesday, plannedMinutes: 25, focusedMinutes: 25).promptLine.contains("25 minutes, finished"))
    }

    @Test func cannedTitlesDontRepeat() {
        let context = TimelapseTitleContext(startedAt: Self.wednesday, plannedMinutes: 25, focusedMinutes: 25)
        let first = TimelapseTitle.canned(context, avoiding: SaidLines())
        let second = TimelapseTitle.canned(context, avoiding: SaidLines().adding(first))
        #expect(first != second)
    }

    @MainActor @Test func brainTitlesAreRememberedAndUnique() async throws {
        let defaults = try #require(UserDefaults(suiteName: "titles-\(UUID())"))
        let brain = PetBrain(forceFallback: true, saidStore: defaults)
        let context = TimelapseTitleContext(startedAt: Self.wednesday, plannedMinutes: 25, focusedMinutes: 25)
        let a = await brain.timelapseTitle(for: context)
        let b = await brain.timelapseTitle(for: context)
        #expect(a != b)
        #expect(SaidLines.load(from: defaults, key: PetBrain.titleKey).lines == [a, b])
    }

    @Test func theCardIsDrawnOnEveryFrame() async throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let writer = TimelapseWriter(rawURL: dir.appending(path: "raw.mp4"), length: 1, fps: 30)
        let extent = CGRect(x: 0, y: 0, width: 640, height: 360)
        for _ in 0..<30 {
            let frame = CIImage(color: CIColor(red: 0.1, green: 0.1, blue: 0.1)).cropped(to: extent)
            while try !writer.append(frame, overlay: nil) { try await Task.sleep(for: .milliseconds(5)) }
        }
        let video = dir.appending(path: "video.mp4")
        #expect(try await writer.finish(to: video))
        let before = try await Self.topLeftBrightness(video)
        await TimelapseTitle.stamp(video, title: "Productive Wednesday", date: Self.wednesday)
        let after = try await Self.topLeftBrightness(video)
        #expect(after > before + 0.05, "white title text now brightens the top-left corner")
    }

    /// Average brightness of the top-left area where the card goes, at the middle of the video.
    private static func topLeftBrightness(_ url: URL) async throws -> Double {
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        let image = try await generator.image(at: CMTime(seconds: 0.5, preferredTimescale: 600)).image
        let ci = CIImage(cgImage: image)
        let area = CGRect(x: 0, y: ci.extent.height * 0.75, width: ci.extent.width * 0.5, height: ci.extent.height * 0.25)
        let average = CIFilter(name: "CIAreaAverage", parameters: [kCIInputImageKey: ci, kCIInputExtentKey: CIVector(cgRect: area)])!.outputImage!
        var pixel = [UInt8](repeating: 0, count: 4)
        CIContext().render(average, toBitmap: &pixel, rowBytes: 4, bounds: CGRect(x: 0, y: 0, width: 1, height: 1), format: .RGBA8, colorSpace: nil)
        return (Double(pixel[0]) + Double(pixel[1]) + Double(pixel[2])) / (3 * 255)
    }
}

struct TimelapseTitleFitTests {
    @Test func onlyTodaysWeekday() {
        let saturday = TimelapseTitleContext(startedAt: ISO8601DateFormatter().date(from: "2026-10-03T12:00:00Z")!, plannedMinutes: 25, focusedMinutes: 25)
        #expect(saturday.fits("Saturday flow") && saturday.fits("Weekend grind"))
        #expect(!saturday.fits("Sunday Night Chill") && !saturday.fits("TGIF focus"))
        let friday = TimelapseTitleContext(startedAt: ISO8601DateFormatter().date(from: "2026-10-02T12:00:00Z")!, plannedMinutes: 25, focusedMinutes: 25)
        #expect(friday.fits("TGIF grind"))
        #expect(friday.promptLine.range(of: #"\(\d\d:\d\d\)"#, options: .regularExpression) != nil)
    }
}
