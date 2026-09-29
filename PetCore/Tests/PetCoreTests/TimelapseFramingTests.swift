import AVFoundation
import CoreImage
import Foundation
import Testing
@testable import PetCore

struct TimelapseFramingTests {
    let landscape = CGRect(x: 0, y: 0, width: 1920, height: 1080)
    let portrait = CGRect(x: 0, y: 0, width: 1080, height: 1920)

    private func framing(_ format: TimelapseFormat, center: CGPoint = CGPoint(x: 0.5, y: 0.5), zoom: TimelapseZoom = .fit) -> TimelapseFraming {
        var framing = TimelapseFraming(format: format)
        framing.placement = TimelapsePlacement(center: center, zoom: zoom)
        return framing
    }

    @Test func eachFormatCutsTheLargestBoxOfItsShape() {
        #expect(framing(.original).crop(in: landscape) == landscape, "original keeps the whole frame")
        #expect(framing(.vertical).crop(in: landscape) == CGRect(x: 657, y: 0, width: 606, height: 1080), "9:16 from a webcam, centred, even")
        #expect(framing(.square).crop(in: landscape) == CGRect(x: 420, y: 0, width: 1080, height: 1080))
        #expect(framing(.portrait).crop(in: portrait).size == CGSize(width: 1080, height: 1350))
        #expect(framing(.landscape).crop(in: portrait).size == CGSize(width: 1080, height: 606))
        #expect(framing(.vertical).crop(in: portrait) == portrait, "already 9:16")
    }

    @Test func zoomShrinksAndPlacementMovesButNeverPastTheEdge() {
        #expect(framing(.square, zoom: .closest).crop(in: landscape) == CGRect(x: 690, y: 270, width: 540, height: 540))
        let left = framing(.vertical, center: CGPoint(x: 0, y: 0.5)).crop(in: landscape)
        #expect(left.minX == 0, "clamped at the left edge")
        // y is measured from the top in placements, from the bottom in Core Image
        let top = framing(.square, center: CGPoint(x: 0.5, y: 0), zoom: .closest).crop(in: landscape)
        #expect(top.maxY == 1080, "near the top of the picture = high y in Core Image")
    }

    @Test func movingReportsTheClampedCentre() {
        let moved = framing(.vertical).moved(to: CGPoint(x: -1, y: 0.5), frameSize: landscape.size)
        #expect(abs(moved.placement.center.x - 303.0 / 1920) < 0.001, "stops where the box touches the edge")
        let box = moved.box(in: landscape.size)
        #expect(box.minX == 0 && abs(box.width - 606.0 / 1920) < 0.001)
    }

    @Test func eachFormatRemembersItsOwnPlacement() throws {
        var framing = framing(.vertical, center: CGPoint(x: 0.2, y: 0.5), zoom: .closer)
        framing.format = .square
        #expect(framing.placement == TimelapsePlacement(), "square starts centred")
        framing.format = .vertical
        #expect(framing.placement.zoom == .closer)
        let decoded = try JSONDecoder().decode(TimelapseFraming.self, from: JSONEncoder().encode(framing))
        #expect(decoded == framing)
    }

    @Test func aVerticalVideoFromALandscapeCamera() async throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "framing-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let writer = TimelapseWriter(rawURL: dir.appending(path: "raw.mp4"), length: 1, fps: 30)
        let crop = framing(.vertical).crop(in: landscape)
        while writer.frames < 10 {
            let frame = CIImage(color: .gray).cropped(to: landscape).cropped(to: crop)
            if try !writer.append(frame, overlay: nil) { try await Task.sleep(for: .milliseconds(5)) }
        }
        let out = dir.appending(path: "out.mp4")
        #expect(try await writer.finish(to: out))
        let track = try #require(try await AVURLAsset(url: out).loadTracks(withMediaType: .video).first)
        #expect(try await track.load(.naturalSize) == CGSize(width: 606, height: 1080))
    }
}
