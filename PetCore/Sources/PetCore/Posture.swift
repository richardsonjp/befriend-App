//
//  Posture.swift
//  PetCore
//
//  The posture checker (M14): while it's on, the camera watches the user's upper body with Vision and compares it
//  with the pose they calibrated as sitting well. Everything stays on the device; no frame is kept.
//

import CoreImage
import Foundation
import Observation
import Vision

/// The upper body, measured so that it doesn't depend on how far the camera is: head height above the shoulders
/// in shoulder widths, and how wide the shoulders look in the frame (wider = leaning in).
public nonisolated struct PosturePose: Codable, Equatable, Sendable {
    public let headRise: Double
    public let shoulderWidth: Double
    /// The shoulder line's slope, radians (0 = level).
    public let tilt: Double

    public init(headRise: Double, shoulderWidth: Double, tilt: Double) {
        self.headRise = headRise
        self.shoulderWidth = shoulderWidth
        self.tilt = tilt
    }

    static func average(_ poses: [PosturePose]) -> PosturePose? {
        guard !poses.isEmpty else { return nil }
        let n = Double(poses.count)
        return PosturePose(headRise: poses.map(\.headRise).reduce(0, +) / n,
                           shoulderWidth: poses.map(\.shoulderWidth).reduce(0, +) / n,
                           tilt: poses.map(\.tilt).reduce(0, +) / n)
    }
}

/// What one camera frame shows.
public nonisolated enum PostureReading: Equatable, Sendable {
    /// No one in view.
    case nobody
    /// Someone, but not their shoulders and head: usually a camera that moved.
    case partial
    case pose(PosturePose)
}

public nonisolated enum PostureVerdict: Equatable, Sendable {
    case good, slouching, nobody
}

/// Judges a pose against the calibrated one. Pure, so it's tested without a camera.
public nonisolated enum PostureScore {
    /// The head may sink to this share of its calibrated height above the shoulders.
    static let headDropAllowed = 0.80
    /// The shoulders may look this much wider (closer to the screen) than calibrated.
    static let leanInAllowed = 1.20
    /// About 10° of shoulder tilt beyond the calibrated one.
    static let tiltAllowed = 0.17

    public static func judge(_ reading: PostureReading, baseline: PosturePose) -> PostureVerdict {
        guard case .pose(let pose) = reading else { return .nobody }
        let slumped = pose.headRise < baseline.headRise * headDropAllowed
        let leaning = pose.shoulderWidth > baseline.shoulderWidth * leanInAllowed
        let tilted = abs(pose.tilt - baseline.tilt) > tiltAllowed
        return slumped || leaning || tilted ? .slouching : .good
    }

    /// Too far from the calibration to be the same person sitting in the same spot: the camera likely moved.
    static func implausible(_ reading: PostureReading, baseline: PosturePose) -> Bool {
        switch reading {
        case .nobody: false
        case .partial: true
        case .pose(let pose):
            !(0.4...2.5).contains(pose.headRise / baseline.headRise) || !(0.5...2).contains(pose.shoulderWidth / baseline.shoulderWidth)
        }
    }
}

/// Turns frame-by-frame verdicts into what the user sees: red only after a sustained slouch, a nudge after a long
/// one (rate-limited), and a re-calibration hint when the camera seems to have moved.
public nonisolated struct PostureTracker: Sendable {
    static let slouchBeforeRed: TimeInterval = 5
    static let slouchBeforeNudge: TimeInterval = 60
    static let nudgeEvery: TimeInterval = 10 * 60
    static let oddBeforeHint: TimeInterval = 3 * 60

    public private(set) var shown = PostureVerdict.nobody
    public private(set) var needsRecalibration = false
    private var slouchingSince: Date?
    private var lastNudge: Date?
    private var oddSince: Date?

    /// Returns true when the friend should nudge the user now.
    mutating func observe(_ verdict: PostureVerdict, implausible: Bool, at now: Date) -> Bool {
        oddSince = implausible ? (oddSince ?? now) : nil
        needsRecalibration = oddSince.map { now.timeIntervalSince($0) >= Self.oddBeforeHint } ?? false

        guard verdict == .slouching else {
            slouchingSince = nil
            shown = verdict
            return false
        }
        let since = slouchingSince ?? now
        slouchingSince = since
        let slouched = now.timeIntervalSince(since)
        if slouched >= Self.slouchBeforeRed { shown = .slouching }
        guard slouched >= Self.slouchBeforeNudge, lastNudge.map({ now.timeIntervalSince($0) >= Self.nudgeEvery }) ?? true else {
            return false
        }
        lastNudge = now
        return true
    }

    /// A fresh calibration: the hint goes away and timing starts over.
    mutating func reset() {
        self = PostureTracker()
    }
}

/// Runs the checker on a device: owns the on/off switch and the calibration (kept per device), samples the shared
/// camera twice a second while on and visible, and publishes what to show.
@Observable
public final class PostureChecker {
    public enum Status: Equatable { case off, paused, nobody, good, slouching }

    public private(set) var status = Status.off
    public private(set) var baseline: PosturePose?
    public private(set) var needsRecalibration = false
    public var isOn: Bool { status != .off }
    /// The friend should say something: a long slouch (at most every 10 minutes).
    @ObservationIgnored public var onNudge: () -> Void = {}

    public let camera: TimelapseCamera
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private var tracker = PostureTracker()
    @ObservationIgnored private var sampler: Task<Void, Never>?
    @ObservationIgnored private var away = false

    private static let cameraUser = "posture"
    private static let onKey = "posture.on"
    private static let baselineKey = "posture.baseline"
    private static let sampleInterval: Duration = .milliseconds(500)

    public init(camera: TimelapseCamera, defaults: UserDefaults = .standard) {
        self.camera = camera
        self.defaults = defaults
        baseline = defaults.data(forKey: Self.baselineKey).flatMap { try? JSONDecoder().decode(PosturePose.self, from: $0) }
        if defaults.bool(forKey: Self.onKey), baseline != nil, TimelapseCamera.permitted { setOn(true) }
    }

    /// Turning on needs a calibration first (the app shows the calibration sheet when `baseline` is nil).
    public func setOn(_ on: Bool) {
        defaults.set(on, forKey: Self.onKey)
        guard on, baseline != nil else { return stop(.off) }
        status = away ? .paused : .nobody
        if !away { startSampling() }
    }

    /// The iPhone app went off screen (or came back): iOS stops the camera in the background anyway.
    public func setAway(_ away: Bool) {
        self.away = away
        guard isOn else { return }
        if away { stop(.paused) } else { setOn(true) }
    }

    /// Averages about a second of poses as the user's good posture. Keeps the old calibration (and returns false)
    /// if the shoulders and head weren't seen in most frames.
    public func calibrate() async -> Bool {
        camera.start(for: Self.cameraUser)
        defer { if !isOn || away { camera.stop(for: Self.cameraUser) } }
        var poses: [PosturePose] = []
        for _ in 0..<8 {
            try? await Task.sleep(for: .milliseconds(150))
            if case .pose(let pose) = await read() { poses.append(pose) }
        }
        guard poses.count >= 5, let pose = PosturePose.average(poses) else { return false }
        baseline = pose
        defaults.set(try? JSONEncoder().encode(pose), forKey: Self.baselineKey)
        tracker.reset()
        needsRecalibration = false
        return true
    }

    /// Keeps the camera running for a calibration preview even while the checker is off.
    public func preview(_ showing: Bool) {
        if showing { camera.start(for: Self.cameraUser) } else if !isOn || away { camera.stop(for: Self.cameraUser) }
    }

    private func startSampling() {
        guard sampler == nil else { return }
        camera.start(for: Self.cameraUser)
        sampler = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.sampleInterval)
                guard let self, !Task.isCancelled else { return }
                await self.sample()
            }
        }
    }

    private func stop(_ status: Status) {
        sampler?.cancel()
        sampler = nil
        camera.stop(for: Self.cameraUser)
        self.status = status
    }

    private func sample() async {
        guard let baseline, sampler != nil else { return }
        let reading = await read()
        guard sampler != nil else { return } // turned off while Vision ran
        let nudge = tracker.observe(PostureScore.judge(reading, baseline: baseline),
                                    implausible: PostureScore.implausible(reading, baseline: baseline), at: .now)
        status = switch tracker.shown {
        case .good: .good
        case .slouching: .slouching
        case .nobody: .nobody
        }
        needsRecalibration = tracker.needsRecalibration
        if nudge { onNudge() }
    }

    private func read() async -> PostureReading {
        guard let frame = camera.latest else { return .nobody }
        return await Task.detached(priority: .utility) { Self.reading(of: frame) }.value
    }

    /// Vision's body pose: nose (or the ears' midpoint) and both shoulders, in pixels with y up.
    nonisolated static func reading(of image: CIImage) -> PostureReading {
        let request = VNDetectHumanBodyPoseRequest()
        guard (try? VNImageRequestHandler(ciImage: image).perform([request])) != nil,
              let body = request.results?.first,
              let points = try? body.recognizedPoints(.torso).merging(body.recognizedPoints(.face), uniquingKeysWith: { a, _ in a })
        else { return .nobody }
        let size = image.extent.size
        func point(_ joint: VNHumanBodyPoseObservation.JointName) -> CGPoint? {
            guard let p = points[joint], p.confidence >= 0.3 else { return nil }
            return CGPoint(x: p.location.x * size.width, y: p.location.y * size.height)
        }
        let ears = point(.leftEar).flatMap { l in point(.rightEar).map { r in CGPoint(x: (l.x + r.x) / 2, y: (l.y + r.y) / 2) } }
        guard let left = point(.leftShoulder), let right = point(.rightShoulder), let head = point(.nose) ?? ears else {
            return .partial
        }
        let width = hypot(right.x - left.x, right.y - left.y)
        guard width > 1 else { return .partial }
        let middle = CGPoint(x: (left.x + right.x) / 2, y: (left.y + right.y) / 2)
        return .pose(PosturePose(headRise: Double((head.y - middle.y) / width),
                                 shoulderWidth: Double(width / size.width),
                                 tilt: Double(atan2(abs(right.y - left.y), abs(right.x - left.x)))))
    }
}
