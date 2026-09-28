//
//  Timelapse.swift
//  PetCore
//
//  Recording a focus phase as a 1-minute timelapse (M11): the device's camera, the friend and a clock on top,
//  following the pomodoro. Each device records with its own camera and keeps the videos to itself.
//

import AVFoundation
import CoreImage
import Observation
import SwiftUI

/// The camera, keeping only its latest frame for the recorder to sample.
public nonisolated final class TimelapseCamera: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, @unchecked Sendable {
    /// For a live preview (AVCaptureVideoPreviewLayer).
    public let session = AVCaptureSession()
    private let queue = DispatchQueue(label: "befriend.timelapse.camera")
    private let lock = NSLock()
    private var frame: CIImage?
    private var configured = false

    public var latest: CIImage? { lock.withLock { frame } }

    public static var permitted: Bool { AVCaptureDevice.authorizationStatus(for: .video) == .authorized }

    /// Asks the first time; true when the camera may be used.
    public static func requestAccess() async -> Bool {
        await AVCaptureDevice.requestAccess(for: .video)
    }

    /// Hooks a preview layer up to the session. Waits out a configuration in progress on the camera queue:
    /// attaching mid-configuration raises an Objective-C exception, which aborts the app.
    public func attach(_ layer: AVCaptureVideoPreviewLayer) {
        queue.sync { layer.session = session }
    }

    public func start() {
        queue.async { [self] in
            if !configured { configure() }
            if !session.isRunning { session.startRunning() }
        }
    }

    public func stop() {
        queue.async { [self] in
            session.stopRunning()
            lock.withLock { frame = nil }
        }
    }

    private func configure() {
        configured = true
        session.beginConfiguration()
        defer { session.commitConfiguration() }
        session.sessionPreset = .hd1280x720
        #if os(iOS)
        let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .front)
        #else
        let device = AVCaptureDevice.default(for: .video)
        #endif
        guard let device, let input = try? AVCaptureDeviceInput(device: device), session.canAddInput(input) else { return }
        session.addInput(input)
        let output = AVCaptureVideoDataOutput()
        output.alwaysDiscardsLateVideoFrames = true
        output.setSampleBufferDelegate(self, queue: queue)
        guard session.canAddOutput(output) else { return }
        session.addOutput(output)
        #if os(iOS)
        // Held upright on a stand: portrait, mirrored like a selfie.
        if let connection = output.connection(with: .video) {
            if connection.isVideoRotationAngleSupported(90) { connection.videoRotationAngle = 90 }
            if connection.isVideoMirroringSupported { connection.isVideoMirrored = true }
        }
        #endif
    }

    public func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard let pixels = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let image = CIImage(cvPixelBuffer: pixels)
        lock.withLock { frame = image }
    }
}

/// What's drawn over the camera: the friend focusing in the corner, the watermark and the clock.
struct TimelapseOverlay: View {
    let size: CGSize
    let friend: URL?
    let clock: String

    var body: some View {
        let unit = min(size.width, size.height)
        HStack(alignment: .bottom) {
            if let friend {
                PixelImage(url: friend).frame(width: unit * 0.22, height: unit * 0.22)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: unit * 0.005) {
                Text("befriend").font(.system(size: unit * 0.035, weight: .bold, design: .rounded)).opacity(0.85)
                Text(clock).font(.system(size: unit * 0.05, weight: .semibold, design: .rounded).monospacedDigit())
            }
            .foregroundStyle(.white)
            .shadow(color: .black.opacity(0.6), radius: unit * 0.006)
        }
        .padding(unit * 0.04)
        .frame(width: size.width, height: size.height, alignment: .bottom)
    }

    /// Rendered once per second at most: the clock only changes that often.
    func image() -> CIImage? {
        let renderer = ImageRenderer(content: self)
        renderer.scale = 1
        return renderer.cgImage.map { CIImage(cgImage: $0) }
    }
}

/// Samples the camera on a timer while a focus runs and streams the frames into a video.
@Observable
public final class TimelapseRecorder {
    public enum State { case idle, recording, paused }

    public private(set) var state = State.idle {
        didSet { if state != oldValue { onStateChange() } }
    }
    public let camera = TimelapseCamera()
    /// After every state change, including a finish that completes later (the iPhone updates its Live Activity).
    @ObservationIgnored public var onStateChange: () -> Void = {}

    @ObservationIgnored private var writer: TimelapseWriter?
    @ObservationIgnored private var ticker: Task<Void, Never>?
    @ObservationIgnored private var startedAt = Date.now
    @ObservationIgnored private var planned: TimeInterval = 0
    @ObservationIgnored private var interval: TimeInterval = 1
    @ObservationIgnored private var ticks = 0
    @ObservationIgnored private var overlay: (second: Int, image: CIImage?) = (-1, nil)
    /// The friend's frame for a tick, and the clock text ("12:40 / 25:00").
    @ObservationIgnored var content: (_ tick: Int) -> (friend: URL?, clock: String) = { _ in (nil, "") }

    private var workFolder: URL { FileManager.default.temporaryDirectory.appending(path: "befriend-timelapse", directoryHint: .isDirectory) }

    func start(planned: TimeInterval) {
        try? FileManager.default.createDirectory(at: workFolder, withIntermediateDirectories: true)
        writer = TimelapseWriter(rawURL: workFolder.appending(path: "raw-\(UUID().uuidString).mp4"))
        startedAt = .now
        self.planned = planned
        interval = TimelapsePlan.interval(for: planned)
        ticks = 0
        overlay = (-1, nil)
        state = .recording
        camera.start()
        ticker = Task { [weak self] in
            while !Task.isCancelled, let interval = self?.interval { // ends with the recorder, too
                try? await Task.sleep(for: .seconds(interval))
                self?.tick()
            }
        }
    }

    /// The camera turns off while paused; time spent paused never reaches the video.
    func pause() {
        guard state == .recording else { return }
        state = .paused
        camera.stop()
    }

    func resume() {
        guard state == .paused else { return }
        state = .recording
        camera.start()
    }

    /// Ends the recording and files the minute-long video.
    func finish(into library: TimelapseLibrary) async {
        guard let writer, state != .idle else { return }
        let (started, planned, recorded) = (startedAt, planned, Double(writer.frames) * interval)
        stopTicking()
        let video = workFolder.appending(path: "timelapse-\(UUID().uuidString).mp4")
        do {
            if try await writer.finish(to: video) {
                try library.add(video, startedAt: started, plannedSeconds: planned, recordedSeconds: recorded)
            }
        } catch {
            try? FileManager.default.removeItem(at: video)
        }
    }

    private func stopTicking() {
        ticker?.cancel()
        ticker = nil
        camera.stop()
        state = .idle
        writer = nil
    }

    // ponytail: renders on the main actor, a few ms once per ≥0.5 s; move it to a background actor if it ever
    // shows as a hitch.
    private func tick() {
        guard state == .recording, let writer, let frame = camera.latest else { return }
        // The video keeps the size it opened with; the overlay must match it even if the camera turns.
        let size = writer.size ?? TimelapsePlan.size(for: frame.extent)
        let second = Int(Double(ticks) * interval)
        if overlay.second != second {
            let (friend, clock) = content(ticks)
            overlay = (second, TimelapseOverlay(size: size, friend: friend, clock: clock).image())
        }
        if (try? writer.append(frame, overlay: overlay.image)) == true { ticks += 1 }
    }
}

/// Keeps the recorder in step with the pomodoro: a running focus records, a paused one (or a Mac asleep, or an
/// iPhone app off screen) pauses, and leaving focus files the video.
@Observable
public final class TimelapseController {
    public enum Action: Equatable { case none, start, pause, resume, finish }

    public let recorder = TimelapseRecorder()
    public let library: TimelapseLibrary
    /// The device can't record right now (asleep, locked, or the iPhone app isn't on screen).
    @ObservationIgnored public private(set) var away = false
    @ObservationIgnored private var recordingPhase: Int?
    /// Nobody is signed in: nothing records, whatever the pomodoro says.
    @ObservationIgnored private var signedOut = false
    @ObservationIgnored private var last = Pomodoro()

    public init(library: TimelapseLibrary, skin: @escaping () -> InstalledSkin?) {
        self.library = library
        recorder.content = { [weak self] tick in
            let pomodoro = self?.last ?? Pomodoro()
            let planned = pomodoro.settings.focus
            // Real focus time: after the app was away, the jump shows the time that was skipped.
            let clock = Pomodoro.clock(planned - pomodoro.remaining(at: .now)) + " / " + Pomodoro.clock(planned)
            guard let skin = skin() else { return (nil, clock) }
            let clip = skin.clip(InstalledSkin.focus, PetMood.none.rawValue)
            return (skin.frame(clip, tick % max(clip.frames, 1)), clock)
        }
    }

    public var isRecording: Bool { recorder.state != .idle }

    public func sync(_ pomodoro: Pomodoro) {
        last = pomodoro
        let action = signedOut
            ? (isRecording ? Action.finish : .none)
            : Self.action(for: pomodoro, recorder: recorder.state, recordingPhase: recordingPhase, away: away)
        switch action {
        case .none: break
        case .start:
            recordingPhase = pomodoro.phaseID
            recorder.start(planned: pomodoro.settings.focus)
        case .pause: recorder.pause()
        case .resume: recorder.resume()
        case .finish:
            recordingPhase = nil
            let recorder = recorder, library = library
            Task { [weak self] in
                await recorder.finish(into: library)
                self?.sync(self?.last ?? pomodoro) // a new focus that started meanwhile
            }
        }
    }

    /// Signing out stops the camera and files what was recorded; signing in lets the pomodoro drive it again.
    public func setSignedIn(_ signedIn: Bool) {
        signedOut = !signedIn
        sync(last)
    }

    public func setAway(_ away: Bool) {
        self.away = away
        sync(last)
    }

    /// What the recorder should do next for this pomodoro state.
    public static func action(for pomodoro: Pomodoro, recorder: TimelapseRecorder.State, recordingPhase: Int?, away: Bool) -> Action {
        let inFocus = pomodoro.phase == .focus && pomodoro.status != .ready
        let active = recorder != .idle
        guard pomodoro.settings.recordTimelapse, inFocus, !active || recordingPhase == pomodoro.phaseID else {
            return active ? .finish : .none
        }
        let running = pomodoro.status == .running && !away
        switch recorder {
        case .idle: return running && TimelapseCamera.permitted ? .start : .none
        case .recording: return running ? .none : .pause
        case .paused: return running ? .resume : .none
        }
    }
}
