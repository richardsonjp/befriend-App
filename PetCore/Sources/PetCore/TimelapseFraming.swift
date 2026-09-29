//
//  TimelapseFraming.swift
//  PetCore
//
//  Which shape a timelapse is recorded in, and which part of the camera it keeps (M16). The kept area is cut from
//  the full-resolution frame, never scaled up.
//

import CoreGraphics
import Foundation

public nonisolated enum TimelapseFormat: String, Codable, CaseIterable, Identifiable, Sendable {
    case original, vertical, portrait, square, landscape

    public var id: String { rawValue }

    /// Width over height; nil keeps the camera's own shape.
    public var ratio: CGFloat? {
        switch self {
        case .original: nil
        case .vertical: 9 / 16
        case .portrait: 4 / 5
        case .square: 1
        case .landscape: 16 / 9
        }
    }

    public var title: String {
        switch self {
        case .original: "Original"
        case .vertical: "Vertical 9:16"
        case .portrait: "Portrait 4:5"
        case .square: "Square 1:1"
        case .landscape: "Landscape 16:9"
        }
    }

    /// Short enough for a segmented control.
    public var shortTitle: String {
        switch self {
        case .original: "Original"
        case .vertical: "9:16"
        case .portrait: "4:5"
        case .square: "1:1"
        case .landscape: "16:9"
        }
    }

    public var platforms: String {
        switch self {
        case .original: "The camera's own shape"
        case .vertical: "TikTok · Instagram Reels · YouTube Shorts"
        case .portrait: "Instagram post"
        case .square: "Instagram · anywhere"
        case .landscape: "YouTube"
        }
    }
}

/// Preset sizes for the kept area: the biggest that fits, or zoomed in. No free resizing.
public nonisolated enum TimelapseZoom: Double, Codable, CaseIterable, Identifiable, Sendable {
    case fit = 1, closer = 1.5, closest = 2

    public var id: Double { rawValue }
    public var title: String {
        switch self {
        case .fit: "Fit"
        case .closer: "1.5×"
        case .closest: "2×"
        }
    }
}

/// Where the kept area sits: its centre as a share of the camera frame, from the top left, and its zoom.
public nonisolated struct TimelapsePlacement: Codable, Equatable, Sendable {
    public var center = CGPoint(x: 0.5, y: 0.5)
    public var zoom = TimelapseZoom.fit

    public init(center: CGPoint = CGPoint(x: 0.5, y: 0.5), zoom: TimelapseZoom = .fit) {
        self.center = center
        self.zoom = zoom
    }
}

/// The chosen format and, for each format, where its box was put (so switching formats keeps each one's framing).
public nonisolated struct TimelapseFraming: Codable, Equatable, Sendable {
    public var format = TimelapseFormat.original
    private var placements: [String: TimelapsePlacement] = [:]

    public init(format: TimelapseFormat = .original) {
        self.format = format
    }

    public var placement: TimelapsePlacement {
        get { placements[format.rawValue] ?? TimelapsePlacement() }
        set { placements[format.rawValue] = newValue }
    }

    /// The kept part of a frame, in the frame's own (Core Image, y-up) coordinates: the largest rectangle of the
    /// format's shape, shrunk by the zoom, centred where placed but never past the frame's edges, even-sized.
    public func crop(in extent: CGRect) -> CGRect {
        guard let ratio = format.ratio, extent.width > 0, extent.height > 0 else { return extent }
        var width = extent.width, height = width / ratio
        if height > extent.height { (height, width) = (extent.height, extent.height * ratio) }
        width = Self.even(width / placement.zoom.rawValue)
        height = Self.even(height / placement.zoom.rawValue)
        let midX = extent.minX + placement.center.x * extent.width
        let midY = extent.maxY - placement.center.y * extent.height
        let x = min(max(midX - width / 2, extent.minX), extent.maxX - width)
        let y = min(max(midY - height / 2, extent.minY), extent.maxY - height)
        return CGRect(x: x.rounded(.down), y: y.rounded(.down), width: width, height: height)
    }

    /// The kept part as shares of the frame from the top left, for drawing over a preview.
    public func box(in frameSize: CGSize) -> CGRect {
        let crop = crop(in: CGRect(origin: .zero, size: frameSize))
        guard frameSize.width > 0, frameSize.height > 0 else { return CGRect(x: 0, y: 0, width: 1, height: 1) }
        return CGRect(x: crop.minX / frameSize.width, y: 1 - crop.maxY / frameSize.height,
                      width: crop.width / frameSize.width, height: crop.height / frameSize.height)
    }

    /// Moves the box to centre on `center` (shares of the frame), stopping at the frame's edges.
    public func moved(to center: CGPoint, frameSize: CGSize) -> TimelapseFraming {
        var copy = self
        copy.placement.center = center
        let box = copy.box(in: frameSize)
        copy.placement.center = CGPoint(x: box.midX, y: box.midY) // clamped by crop()
        return copy
    }

    private static func even(_ value: CGFloat) -> CGFloat {
        max(2, (value / 2).rounded(.down) * 2)
    }
}
