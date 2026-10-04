//
//  TimelapseTitle.swift
//  PetCore
//
//  A title card for each timelapse (M24): the friend names the focus when it ends ("Productive Wednesday",
//  "TGIF grind"), and the title and the day it was recorded (DD-MM-YYYY) are drawn top-left on every frame.
//

import AVFoundation
import CoreImage
import SwiftUI

/// What the friend knows when it names a focus.
public nonisolated struct TimelapseTitleContext: Sendable {
    public let startedAt: Date
    public let plannedMinutes: Int
    public let focusedMinutes: Int

    public var finished: Bool { focusedMinutes >= plannedMinutes }

    /// "Weekday: Wednesday. Time of day: morning (09:14). Focus: 25 minutes, finished."
    var promptLine: String {
        let weekday = self.weekday
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "HH:mm"
        let time = formatter.string(from: startedAt)
        let focus = finished ? "\(plannedMinutes) minutes, finished" : "stopped early after \(focusedMinutes) of \(plannedMinutes) minutes"
        return "Weekday: \(weekday). Time of day: \(Self.partOfDay(startedAt)) (\(time)). Focus: \(focus)."
    }

    /// "Wednesday".
    var weekday: String { startedAt.formatted(.dateTime.weekday(.wide).locale(Locale(identifier: "en_US"))) }

    /// The small model sometimes names the wrong day: a title may only name this focus's weekday (and TGIF only
    /// on a Friday).
    func fits(_ title: String) -> Bool {
        let words = Set(title.lowercased().split { !$0.isLetter }.map(String.init))
        let days = ["monday", "tuesday", "wednesday", "thursday", "friday", "saturday", "sunday"]
        let today = weekday.lowercased()
        if days.contains(where: { $0 != today && words.contains($0) }) { return false }
        return !words.contains("tgif") || today == "friday"
    }

    static func partOfDay(_ date: Date) -> String {
        switch Calendar.current.component(.hour, from: date) {
        case 5..<12: "morning"
        case 12..<17: "afternoon"
        case 17..<21: "evening"
        default: "late night"
        }
    }

    public init(startedAt: Date, plannedMinutes: Int, focusedMinutes: Int) {
        self.startedAt = startedAt
        self.plannedMinutes = plannedMinutes
        self.focusedMinutes = focusedMinutes
    }
}

public nonisolated enum TimelapseTitle {
    static let maxLength = 32

    /// "01-10-2026", whatever the device's region.
    public static func date(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "dd-MM-yyyy"
        return formatter.string(from: date)
    }

    /// The model's title, tidied: one line, no quotes or hashtags, no trailing full stop, capped.
    static func clean(_ text: String) -> String? {
        let line = text.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        var title = line.trimmingCharacters(in: CharacterSet(charactersIn: "\"'“”‘’#*").union(.whitespaces))
        while title.hasSuffix(".") { title.removeLast() }
        guard !title.isEmpty else { return nil }
        return title.count > maxLength ? String(title.prefix(maxLength)).trimmingCharacters(in: .whitespaces) : title
    }

    /// Without the model: day and time-of-day titles, one not used lately.
    static func canned(_ context: TimelapseTitleContext, avoiding said: SaidLines) -> String {
        let weekday = context.startedAt.formatted(.dateTime.weekday(.wide).locale(Locale(identifier: "en_US")))
        let part = TimelapseTitleContext.partOfDay(context.startedAt).capitalized
        let friday = Calendar.current.component(.weekday, from: context.startedAt) == 6
        let options = (friday ? ["TGIF focus", "Friday wins"] : []) + [
            "Productive \(weekday)", "\(weekday) focus", "\(part) deep work", "\(weekday) grind", "\(part) flow",
            "\(context.focusedMinutes) minutes of focus", "Getting it done", "Heads-down \(weekday)",
        ]
        return options.first { !said.contains($0) } ?? options[0]
    }

    // MARK: Drawing it on the video

    /// The card for a video of this size, drawn on every frame by the export (TimelapseWriter.export).
    @MainActor static func card(size: CGSize, title: String, date: Date) -> CIImage? {
        TimelapseTitleCard(size: size, title: title, date: Self.date(date)).image()
    }
}

/// The title card, top-left, sized to the video.
struct TimelapseTitleCard: View {
    let size: CGSize
    let title: String
    let date: String

    var body: some View {
        let unit = min(size.width, size.height)
        VStack(alignment: .leading, spacing: unit * 0.008) {
            Text(title).font(.system(size: unit * 0.075, weight: .heavy, design: .rounded))
                .lineLimit(2)
                .minimumScaleFactor(0.6)
            Text(date).font(.system(size: unit * 0.04, weight: .semibold, design: .rounded).monospacedDigit())
                .opacity(0.9)
        }
        .foregroundStyle(.white)
        .shadow(color: .black.opacity(0.6), radius: unit * 0.008)
        .padding(unit * 0.045)
        .frame(width: size.width, height: size.height, alignment: .topLeading)
    }

    @MainActor func image() -> CIImage? {
        let renderer = ImageRenderer(content: self)
        renderer.scale = 1
        return renderer.cgImage.map { CIImage(cgImage: $0) }
    }
}
