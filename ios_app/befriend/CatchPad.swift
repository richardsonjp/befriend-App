//
//  CatchPad.swift
//  befriend
//
//  The iPhone as the controller for the Mac games: Catch (M41), Runner (M42) and Rhythm (M43, `RhythmPad`). Tilt it
//  like a steering wheel and the friend runs on the Mac; in Runner, hold the pad to jump. The game itself runs on the Mac; this sends the input
//  60 times a second and shows the score, with a buzz on every catch.
//

import CoreMotion
import Observation
import PetCore
import SwiftUI
import UIKit

@MainActor @Observable
final class CatchPad {
    enum Stage { case calibrate, playing }

    /// A Mac signed in to this account is connected nearby.
    var macNearby = false
    private(set) var isOpen = false
    var game = MacGame.catchFood
    private(set) var stage = Stage.calibrate
    private(set) var status: CatchStatus?
    /// -1…1, for the steering bar.
    private(set) var steer = 0.0
    /// The jump and drop pads are held (Runner).
    private(set) var jumping = false
    private(set) var dropping = false
    /// The Mac didn't answer Ready (an older befriend, or it couldn't start).
    private(set) var noAnswer = false

    let rhythm = RhythmPad()

    @ObservationIgnored var send: (CatchMessage) -> Void = { _ in } {
        didSet { rhythm.send = send }
    }
    /// Opened or closed: the screen stays awake while it's open.
    @ObservationIgnored var onOpenChange: () -> Void = {}

    @ObservationIgnored private let motion = CMMotionManager()
    @ObservationIgnored private var gravity = (x: 0.0, y: -1.0, z: 0.0)
    @ObservationIgnored private var axis = (x: 1.0, y: 0.0)
    @ObservationIgnored private let light = UIImpactFeedbackGenerator(style: .light)
    @ObservationIgnored private let heavy = UIImpactFeedbackGenerator(style: .heavy)
    @ObservationIgnored private let fastLane = CatchLinkSender()

    func open() {
        guard !isOpen else { return }
        isOpen = true
        stage = .calibrate
        status = nil
        noAnswer = false
        Orientation.allow(.allButUpsideDown)
        startMotion()
        onOpenChange()
    }

    /// The hold right now is "straight ahead".
    func ready() {
        axis = CatchGame.tiltAxis(calibrated: gravity)
        stage = .playing
        Orientation.allow(Orientation.current) // steering mustn't turn the screen
        noAnswer = false
        start()
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(3))
            guard let self, self.isOpen, self.stage == .playing, self.status == nil else { return }
            self.notAnswered()
        }
    }

    func playAgain() { start() }

    private func start() {
        guard game == .rhythm else { return send(.start(game)) }
        Task {
            await rhythm.syncClock() // first: starting a song keeps the Mac busy, which would skew the pings
            send(.start(game, rhythm: rhythm.pick))
        }
    }

    func setJump(_ held: Bool) {
        guard held != jumping else { return }
        jumping = held
        sendInput() // now, not on the next motion frame
    }

    func setDrop(_ held: Bool) {
        guard held != dropping else { return }
        dropping = held
        sendInput()
    }
    func pause() { send(.pause) }
    func resume() { send(.resume) }

    func close() {
        if stage == .playing { send(.quit) }
        shut()
    }

    func receive(_ message: CatchMessage) {
        switch message {
        case .state(let status):
            self.status = status
            if status.over || status.paused { // the pads disappear under the finger without an end
                jumping = false
                dropping = false
                rhythm.releaseAll()
            }
        case .hit(.food): light.impactOccurred()
        case .hit(.bomb): heavy.impactOccurred()
        case .link(let link): fastLane.connect(link)
        case .pong(let sent, let mac): rhythm.pong(sent: sent, mac: mac)
        case .clicks(let times): rhythm.clicks(times)
        case .songs(let list): rhythm.setSongs(list)
        case .quit where stage == .playing:
            if status == nil { // it never started: say so instead of closing
                notAnswered()
            } else {
                shut() // ended on the Mac (Esc, or nobody played for a while)
            }
        default: break
        }
    }

    /// Leaving the app mid-game pauses it; the Mac also pauses when the connection drops.
    func backgrounded() {
        if isOpen, stage == .playing, status?.paused == false, status?.over == false { send(.pause) }
    }

    private func notAnswered() {
        stage = .calibrate
        noAnswer = true
        Orientation.allow(.allButUpsideDown)
    }

    private func shut() {
        guard isOpen else { return }
        motion.stopDeviceMotionUpdates()
        fastLane.stop()
        Orientation.allow(.portrait)
        isOpen = false
        stage = .calibrate
        status = nil
        steer = 0
        jumping = false
        dropping = false
        rhythm.releaseAll()
        rhythm.cancelCalibration()
        onOpenChange()
    }

    private func startMotion() {
        guard motion.isDeviceMotionAvailable else { return }
        motion.deviceMotionUpdateInterval = 1.0 / 60
        motion.startDeviceMotionUpdates(to: .main) { [weak self] data, _ in
            guard let self, let g = data?.gravity else { return }
            self.gravity = (g.x, g.y, g.z)
            guard self.stage == .playing else { return }
            self.steer = CatchGame.steer(degrees: CatchGame.tiltDegrees(gravity: self.gravity, axis: self.axis))
            self.sendInput()
        }
    }

    private func sendInput() {
        guard stage == .playing, game != .rhythm, status?.paused != true, status?.over != true else { return }
        fastLane.send(steer: steer, jump: jumping, drop: dropping) // through the router: steady
        send(.input(steer: steer, jump: jumping, drop: dropping)) // Multipeer: the fallback when the router path is blocked
    }
}

struct CatchPadView: View {
    let pad: CatchPad
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    private var landscape: Bool { verticalSizeClass == .compact }

    var body: some View {
        VStack(spacing: 24) {
            HStack {
                Spacer()
                Button("Done", action: pad.close).font(.headline)
            }
            Spacer()
            if !pad.macNearby {
                ContentUnavailableView("Looking for your Mac…", systemImage: "laptopcomputer",
                                       description: Text("Open befriend on your Mac, on the same Wi-Fi."))
            } else if pad.stage == .calibrate, pad.rhythm.tapAlong != nil {
                RhythmTapAlong(rhythm: pad.rhythm)
            } else if pad.stage == .calibrate {
                calibrate
            } else if let status = pad.status {
                playing(status)
            } else {
                ProgressView("Starting on your Mac…")
            }
            Spacer()
        }
        .padding()
    }

    private var calibrate: some View {
        VStack(spacing: 16) {
            Picker("Game", selection: Binding(get: { pad.game }, set: { pad.game = $0 })) {
                ForEach(MacGame.allCases, id: \.self) { Text($0.title) }
            }
            .pickerStyle(.segmented)
            .frame(maxWidth: 280)
            if !landscape { Text(["catch": "🍎🥕🍖 💣", "runner": "🏃 🪙 🌋", "rhythm": "🎵 🟢🔴🟡🔵"][pad.game.rawValue] ?? "").font(.system(size: 44)) }
            if pad.game == .rhythm { RhythmSetup(rhythm: pad.rhythm) }
            if pad.noAnswer {
                Text("Your Mac didn't answer. Make sure befriend on your Mac is up to date, then try again.")
                    .font(.callout)
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
            }
            Text(Self.howToPlay[pad.game] ?? "")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
            Button("Ready", action: pad.ready)
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
        }
    }

    private static let howToPlay: [MacGame: String] = [
        .catchFood: "Hold your iPhone however feels comfortable, then tap Ready. Turn it like a steering wheel to run. Catch the food and dodge the bombs: three bombs and it's over.",
        .runner: "Hold your iPhone however feels comfortable, then tap Ready. Every word on your Mac's screen is a platform: turn the phone to run, Jump (again in the air for a double jump) and Drop through to the line below. Grab the coins and stay above the lava.",
        .rhythm: "Notes fall down the highway on your Mac. Tap the lane of the same colour as each one crosses the line, and hold the long ones to the end. Too many misses and the song stops. Using AirPods? Calibrate first. Add your own songs on the Mac: Rhythm Songs in befriend's menu.",
    ]

    /// Side by side in landscape: the score on the left, the controls on the right.
    private func playing(_ status: CatchStatus) -> some View {
        let layout = landscape ? AnyLayout(HStackLayout(spacing: 48)) : AnyLayout(VStackLayout(spacing: 20))
        return layout {
            VStack(spacing: 12) {
                if let rhythm = status.rhythm { RhythmHealth(status: rhythm) } else { Text(hearts).font(.largeTitle) }
                Text("\(status.score)").font(.system(size: landscape ? 60 : 72, weight: .bold)).monospacedDigit()
                Text("Best \(status.best)").foregroundStyle(.secondary)
            }
            controls(status).frame(maxWidth: 360)
        }
    }

    private func controls(_ status: CatchStatus) -> some View {
        VStack(spacing: 20) {
            if status.over {
                Text(overTitle(status)).font(.title2.bold())
                Button("Play Again", action: pad.playAgain).buttonStyle(.borderedProminent).controlSize(.large)
            } else {
                if pad.game == .rhythm {
                    RhythmLanes(rhythm: pad.rhythm).frame(height: landscape ? 200 : 260)
                } else {
                    SteerBar(steer: pad.steer).frame(height: 12)
                }
                if pad.game == .runner {
                    HStack(spacing: 12) {
                        holdPad("Drop", systemImage: "arrow.down", held: pad.dropping, set: pad.setDrop).frame(maxWidth: 120)
                        holdPad("Jump", systemImage: "arrow.up", held: pad.jumping, set: pad.setJump)
                    }
                    .frame(height: landscape ? 140 : 180)
                }
                pauseButton(paused: status.paused)
            }
        }
    }
}

private extension CatchPadView {
    func pauseButton(paused: Bool) -> some View {
        Button {
            paused ? pad.resume() : pad.pause()
        } label: {
            Label(paused ? "Resume" : "Pause", systemImage: paused ? "play.fill" : "pause.fill")
        }
        .buttonStyle(.bordered)
        .controlSize(.large)
    }

    /// A pad that counts while it's held: Jump (a longer hold jumps higher; press again in the air for a second
    /// jump) and Drop (through the word you stand on).
    func holdPad(_ title: String, systemImage: String, held: Bool, set: @escaping (Bool) -> Void) -> some View {
        RoundedRectangle(cornerRadius: 24)
            .fill(held ? AnyShapeStyle(.tint) : AnyShapeStyle(.tint.opacity(0.25)))
            .overlay { Label(title, systemImage: systemImage).font(.title2.bold()).foregroundStyle(held ? .white : .primary) }
            .contentShape(.rect)
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { _ in set(true) }
                .onEnded { _ in set(false) })
            .accessibilityElement()
            .accessibilityLabel(title)
            .accessibilityAddTraits(.isButton)
    }

    func overTitle(_ status: CatchStatus) -> String {
        guard let rhythm = status.rhythm else { return "Game over" }
        return rhythm.failed ? "Failed" : "Grade \(rhythm.grade) · \(Int((rhythm.accuracy * 100).rounded()))%"
    }

    var hearts: String {
        let lives = max(0, pad.status?.lives ?? 0)
        return String(repeating: "❤️", count: lives) + String(repeating: "🤍", count: max(0, CatchGame.startLives - lives))
    }
}

/// Where the tilt points: a dot that leaves the middle as the friend speeds up.
private struct SteerBar: View {
    let steer: Double

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                Capsule().fill(.quaternary)
                Circle().fill(.tint)
                    .frame(width: geometry.size.height * 1.6)
                    .offset(x: steer * (geometry.size.width / 2 - geometry.size.height))
            }
        }
        .accessibilityHidden(true)
    }
}

/// The app is portrait. Catch's controller turns with the phone until Ready, then stays that way while steering.
@MainActor
enum Orientation {
    static private(set) var allowed = UIInterfaceOrientationMask.portrait

    static var current: UIInterfaceOrientationMask {
        switch scenes.first?.effectiveGeometry.interfaceOrientation {
        case .landscapeLeft: .landscapeLeft
        case .landscapeRight: .landscapeRight
        default: .portrait
        }
    }

    static func allow(_ mask: UIInterfaceOrientationMask) {
        allowed = mask
        for scene in scenes {
            for window in scene.windows {
                var controller = window.rootViewController
                while let shown = controller {
                    shown.setNeedsUpdateOfSupportedInterfaceOrientations()
                    controller = shown.presentedViewController
                }
            }
            if !mask.contains(current) { scene.requestGeometryUpdate(.iOS(interfaceOrientations: mask)) }
        }
    }

    private static var scenes: [UIWindowScene] { UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene } }
}
