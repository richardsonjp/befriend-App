//
//  ScreenWords.swift
//  befriend
//
//  Desktop Runner (M42): the words on the friend's display, as the boxes the friend stands on. The display is captured
//  with ScreenCaptureKit (the Screen Recording permission Explain already asks for), without befriend's own windows
//  (the game layer, the friend), and read with on-device OCR. Nothing is kept or sent anywhere.
//

import AppKit
import os
import ScreenCaptureKit
import Vision

enum ScreenWords {
    private static let log = Logger(subsystem: "com.richardsonjp.befriend", category: "runner")

    /// Each word inside `field` (AppKit coordinates, on `screen`) as a box in the field: top-left origin, y down.
    /// Nil without Screen Recording permission.
    @MainActor static func read(_ field: CGRect, on screen: NSScreen) async -> [CGRect]? {
        guard CGPreflightScreenCaptureAccess() else { return nil }
        let displayID = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            guard let display = content.displays.first(where: { $0.displayID == displayID }) else { return [] }
            let me = ProcessInfo.processInfo.processIdentifier
            let filter = SCContentFilter(display: display, excludingApplications: content.applications.filter { $0.processID == me },
                                         exceptingWindows: [])
            let configuration = SCStreamConfiguration()
            // The field within the display, counted from the display's top-left.
            configuration.sourceRect = CGRect(x: field.minX - screen.frame.minX, y: screen.frame.maxY - field.maxY,
                                              width: field.width, height: field.height)
            configuration.width = Int(field.width * screen.backingScaleFactor)
            configuration.height = Int(field.height * screen.backingScaleFactor)
            configuration.showsCursor = false
            let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
            var request = RecognizeTextRequest()
            request.recognitionLevel = .fast // once a second over the whole display; exact spelling doesn't matter
            request.usesLanguageCorrection = false
            let lines = try await request.perform(on: image)
            let size = field.size
            return lines.flatMap { line -> [CGRect] in
                guard let text = line.topCandidates(1).first else { return [] }
                var words: [CGRect] = []
                text.string.enumerateSubstrings(in: text.string.startIndex..., options: .byWords) { _, range, _, _ in
                    guard let box = text.boundingBox(for: range)?.boundingBox.cgRect else { return } // normalized, y up
                    words.append(CGRect(x: box.minX * size.width, y: (1 - box.maxY) * size.height,
                                        width: box.width * size.width, height: box.height * size.height))
                }
                return words
            }
        } catch {
            log.error("Reading the screen's words failed: \(error.localizedDescription, privacy: .public)")
            return []
        }
    }
}
