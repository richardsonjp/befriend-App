//
//  TimelapseWriter.swift
//  PetCore
//
//  A focus phase becomes a 1-minute video (M11): frames are spread across the planned focus, streamed into an
//  H.264 file at 30 fps as they come, and the file is stretched to exactly a minute when the focus ends, however
//  early. Nothing is kept as loose images, so memory and disk stay flat through a 3-hour focus.
//

import AVFoundation
import CoreImage

public nonisolated enum TimelapsePlan {
    public static let fps: Int32 = 30
    public static let length: TimeInterval = 60
    public static var frames: Int { Int(fps) * Int(length) }
    /// A 1-minute focus can't fill 1,800 frames; it plays slower instead.
    public static let minInterval: TimeInterval = 0.5

    /// Seconds between frames, so the planned focus fills the minute.
    public static func interval(for planned: TimeInterval) -> TimeInterval {
        max(minInterval, planned / Double(frames))
    }

    /// The camera's own frame size, full resolution; H.264 wants even dimensions.
    public static func size(for frame: CGRect) -> CGSize {
        CGSize(width: (frame.width / 2).rounded(.down) * 2, height: (frame.height / 2).rounded(.down) * 2)
    }
}

/// Used from the recorder's encoder queue, one call at a time.
nonisolated final class TimelapseWriter: @unchecked Sendable {
    private let rawURL: URL
    let length: TimeInterval
    private let fps: Int32
    private let context = CIContext()
    private var writer: AVAssetWriter?
    private var input: AVAssetWriterInput?
    private var adaptor: AVAssetWriterInputPixelBufferAdaptor?
    private(set) var size: CGSize?
    private(set) var frames = 0

    init(rawURL: URL, length: TimeInterval = TimelapsePlan.length, fps: Int32 = TimelapsePlan.fps) {
        self.rawURL = rawURL
        self.length = length
        self.fps = fps
    }

    /// Adds a frame with the overlay drawn on top; false when the encoder is still busy (the frame is skipped).
    @discardableResult
    func append(_ frame: CIImage, overlay: CIImage?) throws -> Bool {
        if writer == nil { try open(size: TimelapsePlan.size(for: frame.extent)) }
        guard let input, let adaptor, let size, input.isReadyForMoreMediaData, let pool = adaptor.pixelBufferPool else {
            return false
        }
        var buffer: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer)
        guard let buffer else { return false }
        let image = overlay.map { $0.composited(over: frame.filling(size)) } ?? frame.filling(size)
        context.render(image, to: buffer)
        // Provisional timestamps at 30 fps: skipped time (pauses, sleep) leaves no gap.
        guard adaptor.append(buffer, withPresentationTime: CMTime(value: Int64(frames), timescale: fps)) else { return false }
        frames += 1
        return true
    }

    /// Closes the recording and exports the finished video to `url`; false when nothing was captured.
    func finish(to url: URL, card: CIImage? = nil) async throws -> Bool {
        guard let raw = try await close() else { return false }
        try await Self.export(raw, to: url, length: length, card: card)
        return true
    }

    /// Closes the raw recording; nil when nothing was captured. `export` makes the video from it.
    func close() async throws -> URL? {
        guard let writer, let input, frames > 0 else {
            cancel()
            return nil
        }
        input.markAsFinished()
        writer.endSession(atSourceTime: CMTime(value: Int64(frames), timescale: fps))
        await writer.finishWriting()
        guard writer.status == .completed else {
            try? FileManager.default.removeItem(at: rawURL)
            throw writer.error ?? CocoaError(.fileWriteUnknown)
        }
        return rawURL
    }

    func cancel() {
        writer?.cancelWriting()
        try? FileManager.default.removeItem(at: rawURL)
    }

    private func open(size: CGSize) throws {
        try? FileManager.default.removeItem(at: rawURL)
        let writer = try AVAssetWriter(outputURL: rawURL, fileType: .mp4)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: size.width,
            AVVideoHeightKey: size.height,
        ])
        input.expectsMediaDataInRealTime = true
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: size.width,
            kCVPixelBufferHeightKey as String: size.height,
        ])
        writer.add(input)
        guard writer.startWriting() else { throw writer.error ?? CocoaError(.fileWriteUnknown) }
        writer.startSession(atSourceTime: .zero)
        (self.writer, self.input, self.adaptor, self.size) = (writer, input, adaptor, size)
    }

    /// The finished video in one encoding pass: re-timed to `length` (a full focus is already a minute, an early
    /// end plays slower) with `card` (the title) drawn on every frame. The raw file is removed either way.
    static func export(_ source: URL, to url: URL, length: TimeInterval, card: CIImage?) async throws {
        defer { try? FileManager.default.removeItem(at: source) }
        let asset = AVURLAsset(url: source)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else { throw CocoaError(.fileReadCorruptFile) }
        let range = CMTimeRange(start: .zero, duration: try await asset.load(.duration))
        let composition = AVMutableComposition()
        guard let target = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) else {
            throw CocoaError(.fileWriteUnknown)
        }
        try target.insertTimeRange(range, of: track, at: .zero)
        target.scaleTimeRange(range, toDuration: CMTime(seconds: length, preferredTimescale: 600))
        guard let export = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetHighestQuality) else {
            throw CocoaError(.fileWriteUnknown)
        }
        if let card {
            export.videoComposition = try await AVMutableVideoComposition.videoComposition(with: composition) { request in
                request.finish(with: card.composited(over: request.sourceImage).cropped(to: request.sourceImage.extent), context: nil)
            }
        }
        try? FileManager.default.removeItem(at: url)
        try await export.export(to: url, as: .mp4)
    }
}

extension CIImage {
    /// Scaled to cover `size` and centre-cropped, with its origin at zero.
    nonisolated func filling(_ size: CGSize) -> CIImage {
        let scale = max(size.width / extent.width, size.height / extent.height)
        let scaled = transformed(by: CGAffineTransform(translationX: -extent.minX, y: -extent.minY))
            .transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let dx = (scaled.extent.width - size.width) / 2, dy = (scaled.extent.height - size.height) / 2
        return scaled.transformed(by: CGAffineTransform(translationX: -dx, y: -dy)).cropped(to: CGRect(origin: .zero, size: size))
    }
}
