//
//  Ingest.swift
//  PetCore
//
//  Turns a file into text the on-device model can read, all on this device: text and PDFs as they are, images
//  through Vision (the text in them, and what they show), audio through SpeechAnalyzer, and video as both (its
//  soundtrack, and the text on a frame every few seconds). Audio and video stop after `mediaCap`.
//

import AVFoundation
import CoreMedia
import Foundation
import PDFKit
import Speech
import UniformTypeIdentifiers
import Vision

public nonisolated enum Ingest {
    public static let mediaCap: TimeInterval = 15 * 60
    static let frameEvery: TimeInterval = 5
    static let labelConfidence: Float = 0.3
    static let maxLabels = 6

    public enum Failure: LocalizedError {
        case unsupported, unreadable, nothingFound, speechUnavailable, languageUnsupported(String)

        public var errorDescription: String? {
            switch self {
            case .unsupported: "befriend can read text, PDFs, images, audio and video."
            case .unreadable: "This file couldn't be opened."
            case .nothingFound: "No text or speech was found in this file."
            case .speechUnavailable: "Speech-to-text isn't available on this device."
            case .languageUnsupported(let name): "Speech-to-text doesn't support \(name) on this device."
            }
        }
    }

    public struct Extracted: Sendable {
        public let segments: [(text: String, locator: PassageLocator)]
        public let note: String?
    }

    public static func kind(of url: URL) -> ChatDocumentKind? {
        guard let type = UTType(filenameExtension: url.pathExtension) else { return nil }
        if type.conforms(to: .pdf) { return .pdf }
        if type.conforms(to: .image) { return .image }
        if type.conforms(to: .movie) || type.conforms(to: .video) { return .video }
        if type.conforms(to: .audio) { return .audio }
        if type.conforms(to: .text) || type.conforms(to: .sourceCode) { return .text }
        return nil
    }

    /// `language` is the spoken language for audio and video; the rest detect theirs.
    public static func extract(_ url: URL, kind: ChatDocumentKind, language: Locale,
                               progress: @escaping @Sendable (String) -> Void) async throws -> Extracted {
        let result: Extracted
        switch kind {
        case .text: result = Extracted(segments: [(try readText(url), .none)], note: nil)
        case .pdf: result = Extracted(segments: try pdf(url), note: nil)
        case .image: result = Extracted(segments: [(try await describe(url), .none)], note: nil)
        case .audio, .video: result = try await media(url, video: kind == .video, language: language, progress: progress)
        case .web, .memory: throw Failure.unsupported // pages come in through WebSearch; memory is never a file
        }
        guard result.segments.contains(where: { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) else {
            throw Failure.nothingFound
        }
        return result
    }

    static func readText(_ url: URL) throws -> String {
        var encoding = String.Encoding.utf8
        if let text = try? String(contentsOf: url, usedEncoding: &encoding) { return text }
        guard let text = try? String(contentsOf: url, encoding: .isoLatin1) else { throw Failure.unreadable }
        return text
    }

    static func pdf(_ url: URL) throws -> [(text: String, locator: PassageLocator)] {
        guard let document = PDFDocument(url: url) else { throw Failure.unreadable }
        return (0..<document.pageCount).compactMap { index in
            guard let text = document.page(at: index)?.string, !text.isEmpty else { return nil }
            return (text, .page(index + 1))
        }
    }

    /// The text in an image and a few labels for what it shows. Vision can't describe a scene in detail.
    static func describe(_ url: URL) async throws -> String {
        var ocr = RecognizeTextRequest()
        ocr.automaticallyDetectsLanguage = true
        let lines = try await ocr.perform(on: url).compactMap { $0.topCandidates(1).first?.string }
        let labels = try await ClassifyImageRequest().perform(on: url)
            .filter { $0.confidence >= labelConfidence }
            .prefix(maxLabels)
            .map { $0.identifier.replacingOccurrences(of: "_", with: " ") }
        var parts: [String] = []
        if !labels.isEmpty { parts.append("The image shows: " + labels.joined(separator: ", ") + ".") }
        if !lines.isEmpty { parts.append("Text in the image: " + lines.joined(separator: " ")) }
        return parts.joined(separator: " ")
    }

    // MARK: Audio and video

    static func media(_ url: URL, video: Bool, language: Locale, progress: @escaping @Sendable (String) -> Void) async throws -> Extracted {
        let asset = AVURLAsset(url: url)
        let duration = try await asset.load(.duration).seconds
        let used = min(duration.isFinite ? duration : mediaCap, mediaCap)
        let note = duration > mediaCap ? "Only the first 15 minutes were used." : nil
        var segments: [(text: String, locator: PassageLocator)] = []
        if try await !asset.loadTracks(withMediaType: .audio).isEmpty {
            segments += try await transcribe(asset, seconds: used, language: language, progress: progress)
        }
        if video {
            segments += try await frameText(asset, seconds: used, progress: progress)
        }
        segments.sort { lhs, rhs in
            if case .time(let a) = lhs.locator, case .time(let b) = rhs.locator { return a < b }
            return false
        }
        return Extracted(segments: segments, note: note)
    }

    static func transcribe(_ asset: AVURLAsset, seconds: TimeInterval, language: Locale,
                           progress: @escaping @Sendable (String) -> Void) async throws -> [(text: String, locator: PassageLocator)] {
        guard SpeechTranscriber.isAvailable else { throw Failure.speechUnavailable }
        guard let locale = await SpeechTranscriber.supportedLocale(equivalentTo: language) else {
            throw Failure.languageUnsupported(Locale.current.localizedString(forIdentifier: language.identifier) ?? language.identifier)
        }
        let transcriber = SpeechTranscriber(locale: locale, transcriptionOptions: [], reportingOptions: [],
                                            attributeOptions: [.audioTimeRange])
        if let install = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            progress("Downloading speech model…")
            try await install.downloadAndInstall()
        }
        progress("Preparing audio…")
        let audio = try await exportAudio(asset, seconds: seconds)
        defer { try? FileManager.default.removeItem(at: audio) }
        progress("Transcribing…")
        let file = try AVAudioFile(forReading: audio)
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        let collector = Task {
            var pieces: [(text: String, locator: PassageLocator)] = []
            for try await result in transcriber.results {
                pieces.append((String(result.text.characters), .time(result.range.start.seconds)))
            }
            return pieces
        }
        do {
            if let last = try await analyzer.analyzeSequence(from: file) {
                try await analyzer.finalizeAndFinish(through: last)
            } else {
                await analyzer.cancelAndFinishNow()
            }
        } catch {
            collector.cancel()
            throw error
        }
        return try await collector.value
    }

    /// The first `seconds` of the soundtrack as an audio file SpeechAnalyzer can read.
    static func exportAudio(_ asset: AVURLAsset, seconds: TimeInterval) async throws -> URL {
        guard let export = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetAppleM4A) else {
            throw Failure.unreadable
        }
        export.timeRange = CMTimeRange(start: .zero, duration: CMTime(seconds: seconds, preferredTimescale: 600))
        let output = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString + ".m4a")
        try await export.export(to: output, as: .m4a)
        return output
    }

    /// Text on screen every `frameEvery` seconds, skipping frames that show the same text as the one before.
    static func frameText(_ asset: AVURLAsset, seconds: TimeInterval,
                         progress: @escaping @Sendable (String) -> Void) async throws -> [(text: String, locator: PassageLocator)] {
        guard try await !asset.loadTracks(withMediaType: .video).isEmpty else { return [] }
        progress("Reading the video's frames…")
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 1280, height: 1280)
        let times = stride(from: 0, to: seconds, by: frameEvery).map { CMTime(seconds: $0, preferredTimescale: 600) }
        var ocr = RecognizeTextRequest()
        ocr.recognitionLevel = .fast
        ocr.automaticallyDetectsLanguage = true
        var pieces: [(text: String, locator: PassageLocator)] = []
        var previous = ""
        for await frame in generator.images(for: times) {
            try Task.checkCancellation()
            guard let image = try? frame.image else { continue }
            let text = (try? await ocr.perform(on: image))?.compactMap { $0.topCandidates(1).first?.string }.joined(separator: " ") ?? ""
            guard !text.isEmpty, text != previous else { continue }
            previous = text
            pieces.append(("On screen: " + text, .time(frame.requestedTime.seconds)))
        }
        return pieces
    }
}
