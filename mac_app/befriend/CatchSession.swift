//
//  CatchSession.swift
//  befriend
//
//  The Mac games on the friend's display, in a click-through layer; the iPhone starts them and steers.
//  Catch (M41): food and bombs fall and the friend runs along the bottom (`CatchGame`).
//  Runner (M42): the friend runs and jumps on the real windows' top edges above rising lava (`RunnerGame`).
//

import AppKit
import Observation
import PetCore
import SwiftUI

@MainActor @Observable
final class CatchSession {
    enum Phase { case off, playing, paused, over }

    struct Pop: Identifiable {
        let id = UUID()
        let text: String
        let x: Double
        let y: Double
        let at: Date
    }

    private static func bestKey(_ mode: MacGame) -> String { "\(mode.rawValue).best" }
    /// Runner re-reads the windows this often, so moving one changes the level.
    private static let windowReadInterval: TimeInterval = 1.0 / 15 // smooth enough to ride a dragged window
    /// Paused, over or without the phone this long, the game ends by itself.
    private static let idleLimit: TimeInterval = 30
    /// Tilt is sent unreliably 60 times a second; none for this long means the phone stopped steering.
    private static let tiltTimeout: TimeInterval = 0.5
    private static let popDuration: TimeInterval = 0.8

    private(set) var phase = Phase.off
    private(set) var mode = MacGame.catchFood
    private(set) var game: CatchGame?
    private(set) var runner: RunnerGame?
    private(set) var pops: [Pop] = []
    private(set) var best = 0
    var isOn: Bool { phase != .off }

    @ObservationIgnored var send: (CatchMessage) -> Void = { _ in }
    /// The game ended (quit, Esc or idle): the controller puts the friend back where presence says.
    @ObservationIgnored var onEnd: () -> Void = {}

    @ObservationIgnored private let walker: FriendWalker
    @ObservationIgnored private let pet: PetStateMachine
    @ObservationIgnored private let hotkey: ExplainHotkey
    @ObservationIgnored private var field = CGRect.zero
    @ObservationIgnored private var steer = 0.0
    @ObservationIgnored private var jump = false
    @ObservationIgnored private var windowsReadAt = Date.distantPast
    @ObservationIgnored private var lastTilt = Date.distantPast
    /// While the fast lane delivers, Multipeer's copies of the same tilt arrive later and are ignored.
    @ObservationIgnored private var lastFastTilt = Date.distantPast
    @ObservationIgnored private let fastLane = CatchLinkListener()
    @ObservationIgnored private var lastTick = Date.now
    @ObservationIgnored private var idleSince: Date?
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var window: NSWindow?
    @ObservationIgnored private var rng = SystemRandomNumberGenerator()
    @ObservationIgnored private var escapeBefore: (() -> Void)?

    /// Picking a box to explain holds Esc; a game doesn't start over it.
    @ObservationIgnored var explaining: () -> Bool = { false }

    init(walker: FriendWalker, pet: PetStateMachine, hotkey: ExplainHotkey) {
        self.walker = walker
        self.pet = pet
        self.hotkey = hotkey
        fastLane.onInput = { [weak self] steer, jump in
            self?.steer = steer
            self?.jump = jump
            self?.lastTilt = .now
            self?.lastFastTilt = .now
        }
    }

    func handle(_ message: CatchMessage) {
        switch message {
        case .start(let mode): begin(mode)
        case .input(let value, let jump) where value.isFinite && Date.now.timeIntervalSince(lastFastTilt) > Self.tiltTimeout:
            steer = max(-1, min(1, value))
            self.jump = jump
            lastTilt = .now
        case .pause where phase == .playing: pause()
        case .resume where phase == .paused:
            phase = .playing
            idleSince = nil
            lastTick = .now
            publish()
        case .quit: end(tellPhone: false) // an echo could close the phone's next game
        default: break
        }
    }

    /// The phone left (locked, backgrounded, out of range): pause, and end if it doesn't come back.
    /// Back: it hears how things stand, or that the game ended while it was gone.
    func phoneConnected(_ connected: Bool) {
        if !connected, phase == .playing { pause() }
        guard connected else { return }
        if phase == .off { return send(.quit) }
        publish()
        if let link = fastLane.link { send(.link(link)) }
    }

    func end(tellPhone: Bool = true) {
        guard phase != .off else { return }
        phase = .off
        timer?.invalidate()
        timer = nil
        window?.orderOut(nil)
        window = nil
        game = nil
        runner = nil
        pops = []
        hotkey.catchEscape = false
        fastLane.stop()
        if let escapeBefore { hotkey.onEscape = escapeBefore }
        escapeBefore = nil
        walker.stopPlaying()
        if tellPhone { send(.quit) }
        onEnd()
    }

    // MARK: Running

    private func begin(_ mode: MacGame) {
        if phase == .off {
            guard !explaining(), let screen = walker.panel?.characterScreen ?? NSScreen.main else { return send(.quit) }
            field = screen.visibleFrame
            walker.play(in: field)
            showOverlay()
            // Esc is the Carbon hot key picking a box uses; explaining is blocked during a game, so they never share it.
            escapeBefore = hotkey.onEscape
            hotkey.onEscape = { [weak self] in self?.end() }
            hotkey.catchEscape = true
            let timer = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.tick() }
            }
            RunLoop.main.add(timer, forMode: .common)
            self.timer = timer
            fastLane.start { [weak self] in self?.send(.link($0)) }
        }
        self.mode = mode
        best = UserDefaults.standard.integer(forKey: Self.bestKey(mode))
        game = mode == .catchFood ? CatchGame(width: field.width, height: field.height) : nil
        runner = nil
        if mode == .runner {
            var runner = RunnerGame(width: field.width, height: field.height)
            runner.setWindows(windows())
            self.runner = runner
            windowsReadAt = .now
        }
        phase = .playing
        steer = 0
        jump = false
        pops = []
        idleSince = nil
        lastTick = .now
        publish()
    }

    private func pause() {
        phase = .paused
        idleSince = .now
        publish()
    }

    private func tick() {
        let now = Date.now
        let dt = min(now.timeIntervalSince(lastTick), 0.05) // a stalled frame doesn't teleport anything
        lastTick = now
        pops.removeAll { now.timeIntervalSince($0.at) > Self.popDuration }
        guard phase == .playing else {
            if let idleSince, now.timeIntervalSince(idleSince) > Self.idleLimit { end() }
            return
        }
        if now.timeIntervalSince(lastTilt) > Self.tiltTimeout { (steer, jump) = (0, false) }
        if var game {
            let events = game.step(dt: dt, steer: steer, using: &rng)
            self.game = game
            walker.run(to: CGPoint(x: field.minX + game.friendX, y: field.minY), steer: steer)
            for event in events {
                switch event {
                case .caught(_, let points, let x): scored("+\(points)", x: x, y: game.height - CatchGame.friendSize)
                case .bomb(let x): hurt(x: x, y: game.height - CatchGame.friendSize)
                case .over: over(score: game.score)
                }
            }
            if !events.isEmpty { publish() }
        } else if var runner {
            if now.timeIntervalSince(windowsReadAt) > Self.windowReadInterval {
                runner.setWindows(windows())
                windowsReadAt = now
            }
            let events = runner.step(dt: dt, steer: steer, jump: jump, using: &rng)
            self.runner = runner
            walker.run(to: CGPoint(x: field.minX + runner.x, y: field.maxY - runner.y), steer: steer)
            for event in events {
                switch event {
                case .coin(let x, let y): scored("+1", x: x, y: y)
                case .burned(let x): hurt(x: x, y: runner.lavaTop)
                case .over: over(score: runner.score)
                }
            }
            if !events.isEmpty { publish() }
        }
    }

    private func scored(_ text: String, x: Double, y: Double) {
        pops.append(Pop(text: text, x: x, y: y, at: .now))
        send(.hit(.food))
        pet.apply(PetReaction(action: .cheer, mood: .excited, dialogue: ""))
    }

    private func hurt(x: Double, y: Double) {
        pops.append(Pop(text: "💥", x: x, y: y, at: .now))
        send(.hit(.bomb))
        pet.apply(PetReaction(action: .cry, mood: .concerned, dialogue: ""))
    }

    private func over(score: Int) {
        phase = .over
        idleSince = .now
        guard score > best else { return }
        best = score
        UserDefaults.standard.set(best, forKey: Self.bestKey(mode))
    }

    private func publish() {
        guard let (score, lives) = game.map({ ($0.score, $0.lives) }) ?? runner.map({ ($0.score, $0.lives) }) else { return }
        send(.state(CatchStatus(score: score, lives: lives, best: max(best, score),
                                paused: phase == .paused, over: phase == .over)))
    }

    /// The normal windows on the friend's display, front to back, in the field's coordinates (top-left, y down).
    /// Window bounds need no permission; only titles do.
    private func windows() -> [RunnerGame.Window] {
        let me = ProcessInfo.processInfo.processIdentifier
        // CGWindowList counts from the top-left of the main display; AppKit from its bottom-left.
        let fieldTop = (NSScreen.screens.first?.frame.height ?? field.maxY) - field.maxY
        let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        return list.compactMap { info in
            guard (info[kCGWindowLayer as String] as? Int) == 0, (info[kCGWindowOwnerPID as String] as? pid_t) != me,
                  (info[kCGWindowAlpha as String] as? Double ?? 1) > 0, let id = info[kCGWindowNumber as String] as? Int,
                  let bounds = info[kCGWindowBounds as String] as CFTypeRef?,
                  let rect = CGRect(dictionaryRepresentation: bounds as! CFDictionary) else { return nil }
            return RunnerGame.Window(id: id, frame: rect.offsetBy(dx: -field.minX, dy: -fieldTop))
        }
    }

    // MARK: Overlay

    private func showOverlay() {
        let window = NSWindow(contentRect: field, styleMask: .borderless, backing: .buffered, defer: false)
        window.level = NSWindow.Level(rawValue: NSWindow.Level.floating.rawValue - 1) // under the friend's panel
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.ignoresMouseEvents = true // clicks go to the apps underneath
        window.isReleasedWhenClosed = false
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        window.contentView = NSHostingView(rootView: CatchField(session: self))
        window.setFrame(field, display: true)
        window.orderFrontRegardless()
        self.window = window
    }
}

/// The falling items, the score and lives, and the "+2" pops. y grows downwards, as in `CatchGame`.
private struct CatchField: View {
    let session: CatchSession

    var body: some View {
        ZStack(alignment: .top) {
            Color.black.opacity(0.12)
            Canvas { context, size in
                if let game = session.game {
                    for item in game.items {
                        context.draw(Text(item.emoji).font(.system(size: CatchGame.itemSize * 0.8)),
                                     at: CGPoint(x: item.x, y: item.y))
                    }
                }
                if let runner = session.runner { drawRunner(runner, in: context, size: size) }
                for pop in session.pops {
                    let age = Date.now.timeIntervalSince(pop.at)
                    var faded = context
                    faded.opacity = max(0, 1 - age / 0.8)
                    faded.draw(Text(pop.text).font(.title.bold()).foregroundStyle(.white),
                               at: CGPoint(x: pop.x, y: pop.y - 30 - age * 60))
                }
            }
            if let (score, lives) = session.game.map({ ($0.score, $0.lives) }) ?? session.runner.map({ ($0.score, $0.lives) }) {
                header(score: score, lives: lives)
            }
        }
        .ignoresSafeArea()
    }

    /// The window edges glow faintly so you can see what's solid; clouds, coins and the lava are drawn.
    private func drawRunner(_ runner: RunnerGame, in context: GraphicsContext, size: CGSize) {
        for ledge in runner.ledges {
            let edge = CGRect(x: ledge.minX, y: ledge.y - 3, width: ledge.maxX - ledge.minX, height: 6)
            if ledge.isCloud {
                context.fill(Path(roundedRect: edge.insetBy(dx: 0, dy: -8).offsetBy(dx: 0, dy: 8), cornerRadius: 12), with: .color(.white.opacity(0.9)))
                context.draw(Text("☁️").font(.system(size: 28)), at: CGPoint(x: edge.midX, y: ledge.y + 10))
            } else {
                context.fill(Path(roundedRect: edge, cornerRadius: 3), with: .color(.yellow.opacity(0.45)))
            }
        }
        for coin in runner.coins {
            context.draw(Text("🪙").font(.system(size: RunnerGame.coinSize * 0.8)), at: CGPoint(x: coin.x, y: coin.y))
        }
        let lava = CGRect(x: 0, y: runner.lavaTop, width: size.width, height: max(0, size.height - runner.lavaTop))
        context.fill(Path(lava), with: .linearGradient(Gradient(colors: [.orange, .red.opacity(0.9)]),
                                                       startPoint: CGPoint(x: 0, y: lava.minY), endPoint: CGPoint(x: 0, y: lava.maxY)))
    }

    private func header(score: Int, lives: Int) -> some View {
        VStack(spacing: 6) {
            HStack(spacing: 14) {
                Text(String(repeating: "❤️", count: max(0, lives)) + String(repeating: "🤍", count: max(0, CatchGame.startLives - lives)))
                Text("\(score)").monospacedDigit()
                Text("Best \(max(session.best, score))").foregroundStyle(.secondary)
            }
            .font(.title2.bold())
            switch session.phase {
            case .paused: Text("Paused · resume on your iPhone, Esc ends").font(.headline)
            case .over: Text("Game over · play again on your iPhone, Esc ends").font(.headline)
            default: EmptyView()
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 10)
        .background(.regularMaterial, in: .rect(cornerRadius: 14))
        .padding(.top, 16)
    }
}
