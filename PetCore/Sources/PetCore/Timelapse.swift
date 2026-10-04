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

/// The camera, keeping only its latest frame for its users to sample: the timelapse recorder and the posture
/// checker (M14) share it, and it runs while either needs it.
public nonisolated final class TimelapseCamera: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, @unchecked Sendable {
    /// For a live preview (AVCaptureVideoPreviewLayer).
    public let session = AVCaptureSession()
    private let queue = DispatchQueue(label: "befriend.timelapse.camera")
    private let lock = NSLock()
    private var frame: CIImage?
    private var configured = false
    /// Who needs the camera now; touched only on `queue`.
    private var users: Set<String> = []
    /// The rotation the frames should have (iPhone: follows how the phone is held); read under `lock`.
    private var rotationAngle: CGFloat = 0
    #if os(iOS)
    private var rotation: AVCaptureDevice.RotationCoordinator?
    private var rotationObservation: NSKeyValueObservation?
    #endif

    public var latest: CIImage? { lock.withLock { frame } }

    public static var permitted: Bool { AVCaptureDevice.authorizationStatus(for: .video) == .authorized }

    /// Asks the first time; true when the camera may be used.
    public static func requestAccess() async -> Bool {
        await AVCaptureDevice.requestAccess(for: .video)
    }

    /// Hooks a preview layer up to the session once any configuration in progress on the camera queue is done
    /// (attaching mid-configuration raises an Objective-C exception, which aborts the app). Never waits: waiting
    /// here froze the screen while the camera started.
    public func attach(_ layer: AVCaptureVideoPreviewLayer) {
        queue.async { [session] in
            DispatchQueue.main.async { layer.session = session }
        }
    }

    /// Sets the camera up ahead of time without turning it on, so a recording starts at once.
    public func prepare() {
        queue.async { [self] in if !configured { configure() } }
    }

    public func start(for user: String) {
        queue.async { [self] in
            users.insert(user)
            if !configured { configure() }
            if !session.isRunning { session.startRunning() }
        }
    }

    /// Stops the camera once no one else needs it.
    public func stop(for user: String) {
        queue.async { [self] in
            users.remove(user)
            guard users.isEmpty else { return }
            session.stopRunning()
            lock.withLock { frame = nil }
        }
    }

    private func configure() {
        session.beginConfiguration()
        defer { session.commitConfiguration() }
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
        // 1080p: plenty for a 1-minute timelapse, and a quarter of 4K's work per frame (4K made recording stutter).
        // Chosen once the camera is attached: with no input the session accepts any preset, and one the camera
        // can't film is then refused, leaving no picture at all.
        session.sessionPreset = [.hd1920x1080, .high].first(where: session.canSetSessionPreset) ?? .high
        configured = true // a camera that couldn't be attached (no permission yet) is tried again on the next start
        #if os(iOS)
        // Upright the way the phone is held (portrait on a stand), mirrored like a selfie. A fixed 90° left some
        // recordings landscape; the rotation coordinator follows the real orientation instead.
        if let connection = output.connection(with: .video) {
            if connection.isVideoMirroringSupported { connection.isVideoMirrored = true }
            let coordinator = AVCaptureDevice.RotationCoordinator(device: device, previewLayer: nil)
            rotate(connection, to: coordinator.videoRotationAngleForHorizonLevelCapture)
            rotationObservation = coordinator.observe(\.videoRotationAngleForHorizonLevelCapture, options: [.new]) { [weak self] coordinator, _ in
                let angle = coordinator.videoRotationAngleForHorizonLevelCapture
                self?.queue.async { self?.rotate(connection, to: angle) }
            }
            rotation = coordinator
        }
        #endif
    }

    private func rotate(_ connection: AVCaptureConnection, to angle: CGFloat) {
        if connection.isVideoRotationAngleSupported(angle) { connection.videoRotationAngle = angle }
        lock.withLock { rotationAngle = angle }
    }

    public func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard let pixels = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        var image = CIImage(cvPixelBuffer: pixels)
        let angle = lock.withLock { rotationAngle }
        // Belt and braces: a portrait angle must give a portrait frame, even if the connection didn't rotate it.
        if angle == 90 || angle == 270, image.extent.width > image.extent.height {
            image = image.oriented(angle == 90 ? .right : .left)
        }
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

    private static let cameraUser = "timelapse"

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
    /// Frames are drawn and encoded here, off the main thread: a full frame each tick made the screen stutter.
    @ObservationIgnored private let encoder = DispatchQueue(label: "befriend.timelapse.encoder", qos: .userInitiated)
    /// A frame is still being encoded: the next tick is skipped rather than queued.
    @ObservationIgnored private var encoding = false
    /// The video's size, fixed by the first frame.
    @ObservationIgnored private var videoSize: CGSize?
    /// The friend's frame for a tick, and the clock text ("12:40 / 25:00").
    @ObservationIgnored var content: (_ tick: Int) -> (friend: URL?, clock: String) = { _ in (nil, "") }

    private var workFolder: URL { FileManager.default.temporaryDirectory.appending(path: "befriend-timelapse", directoryHint: .isDirectory) }

    /// The shape and part of the camera this recording keeps; fixed when it starts (M16).
    public private(set) var framing = TimelapseFraming()

    func start(planned: TimeInterval, framing: TimelapseFraming) {
        self.framing = framing
        try? FileManager.default.createDirectory(at: workFolder, withIntermediateDirectories: true)
        writer = TimelapseWriter(rawURL: workFolder.appending(path: "raw-\(UUID().uuidString).mp4"))
        startedAt = .now
        self.planned = planned
        interval = TimelapsePlan.interval(for: planned)
        ticks = 0
        overlay = (-1, nil)
        videoSize = nil
        state = .recording
        camera.start(for: Self.cameraUser)
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
        camera.stop(for: Self.cameraUser)
    }

    func resume() {
        guard state == .paused else { return }
        state = .recording
        camera.start(for: Self.cameraUser)
    }

    /// Ends the recording and files the video, named by the friend (title and date drawn top-left). The library
    /// shows it as saving meanwhile: closing the file, the title and one encoding pass take a while.
    func finish(into library: TimelapseLibrary, title: @escaping (TimelapseTitleContext) async -> String?) async {
        guard let writer, state != .idle else { return }
        let started = startedAt
        stopTicking()
        library.beginSaving(started)
        defer { library.endSaving(started) }
        await withCheckedContinuation { done in encoder.async { done.resume() } } // the frame in flight lands first
        let (planned, recorded) = (planned, Double(writer.frames) * interval)
        let context = TimelapseTitleContext(startedAt: started, plannedMinutes: max(1, Int((planned / 60).rounded())),
                                            focusedMinutes: max(1, Int((recorded / 60).rounded())))
        // The friend thinks of a title while the file closes.
        let naming = Task { await title(context) }
        let video = workFolder.appending(path: "timelapse-\(UUID().uuidString).mp4")
        do {
            guard let raw = try await writer.close() else { return naming.cancel() }
            let name = await naming.value
            let card = name.flatMap { name in writer.size.flatMap { TimelapseTitle.card(size: $0, title: name, date: started) } }
            try await TimelapseWriter.export(raw, to: video, length: writer.length, card: card)
            try library.add(video, startedAt: started, plannedSeconds: planned, recordedSeconds: recorded, title: name)
        } catch {
            try? FileManager.default.removeItem(at: video)
        }
    }

    private func stopTicking() {
        ticker?.cancel()
        ticker = nil
        camera.stop(for: Self.cameraUser)
        state = .idle
        writer = nil
    }

    /// The overlay (SwiftUI) is drawn here once a second; the frame is composed and encoded on `encoder`.
    private func tick() {
        guard state == .recording, !encoding, let writer, let full = camera.latest else { return }
        let frame = full.cropped(to: framing.crop(in: full.extent))
        // The video keeps the size it opened with; the overlay must match it even if the camera turns.
        let size = videoSize ?? TimelapsePlan.size(for: frame.extent)
        videoSize = size
        let second = Int(Double(ticks) * interval)
        if overlay.second != second {
            let (friend, clock) = content(ticks)
            overlay = (second, TimelapseOverlay(size: size, friend: friend, clock: clock).image())
        }
        encoding = true
        let image = overlay.image
        encoder.async { [weak self] in
            let added = (try? writer.append(frame, overlay: image)) == true
            DispatchQueue.main.async {
                guard let self else { return }
                self.encoding = false
                if added { self.ticks += 1 }
            }
        }
    }
}

/// Keeps the recorder in step with the pomodoro: a running focus records, a paused one (or a Mac asleep, or an
/// iPhone app off screen) pauses, and leaving focus files the video.
@Observable
public final class TimelapseController {
    public enum Action: Equatable { case none, start, pause, resume, finish }

    public let recorder = TimelapseRecorder()
    public let library: TimelapseLibrary
    /// Names a finished focus in the friend's voice (the app's brain); nil leaves the video untitled.
    @ObservationIgnored public var title: (TimelapseTitleContext) async -> String? = { _ in nil }
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
        if pomodoro.settings.recordTimelapse, TimelapseCamera.permitted { recorder.camera.prepare() }
        let action = signedOut
            ? (isRecording ? Action.finish : .none)
            : Self.action(for: pomodoro, recorder: recorder.state, recordingPhase: recordingPhase, away: away)
        switch action {
        case .none: break
        case .start:
            recordingPhase = pomodoro.phaseID
            recorder.start(planned: pomodoro.settings.focus, framing: pomodoro.settings.framing)
        case .pause: recorder.pause()
        case .resume: recorder.resume()
        case .finish:
            recordingPhase = nil
            let recorder = recorder, library = library, title = title
            Task { [weak self] in
                await recorder.finish(into: library, title: title)
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
        let inFocus = pomodoro.status != .ready
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
