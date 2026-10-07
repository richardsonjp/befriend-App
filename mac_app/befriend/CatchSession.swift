//
//  CatchSession.swift
//  befriend
//
//  The Mac games on the friend's display, in a click-through layer; the iPhone starts them and steers.
//  Catch (M41): food and bombs fall and the friend runs along the bottom (`CatchGame`).
//  Runner (M42): the friend runs and jumps across the words on screen above rising lava (`RunnerGame`).
//  Rhythm (M43): a song plays and notes fall down a highway; the phone's four lanes play them (`RhythmJudge`).
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

    private static func bestKey(_ mode: MacGame, _ pick: RhythmPick?) -> String {
        pick.map { "rhythm.\($0.song).\($0.difficulty.rawValue).best" } ?? "\(mode.rawValue).best"
    }
    /// The friend cheers or cries at most this often in Rhythm, where notes come several a second.
    private static let reactionInterval: TimeInterval = 1
    /// Runner re-reads the screen's words this often, so scrolling or typing changes the level.
    private static let wordReadInterval: TimeInterval = 1
    /// Paused, over or without the phone this long, the game ends by itself.
    private static let idleLimit: TimeInterval = 30
    /// Tilt is sent unreliably 60 times a second; none for this long means the phone stopped steering.
    private static let tiltTimeout: TimeInterval = 0.5
    private static let popDuration: TimeInterval = 0.8

    private(set) var phase = Phase.off
    private(set) var mode = MacGame.catchFood
    private(set) var game: CatchGame?
    private(set) var runner: RunnerGame?
    /// Runner without Screen Recording: there are no words to stand on, only the clouds.
    private(set) var wordsBlocked = false
    private(set) var rhythm: RhythmJudge?
    private(set) var rhythmPick: RhythmPick?
    /// Seconds into the song, corrected by the player's calibration (what they hear now).
    private(set) var songTime = 0.0
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
    @ObservationIgnored private var drop = false
    @ObservationIgnored private var wordsReadAt = Date.distantPast
    @ObservationIgnored private var readingWords = false
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
    @ObservationIgnored private let player = RhythmPlayer()
    @ObservationIgnored private var pausedAt = 0.0
    @ObservationIgnored private var reactedAt = Date.distantPast
    @ObservationIgnored private var clicksDone: Task<Void, Never>?

    /// Picking a box to explain holds Esc; a game doesn't start over it.
    @ObservationIgnored var explaining: () -> Bool = { false }

    /// A Rhythm song ready to play: built in, or added on the Mac.
    struct RhythmTrack {
        let title: String
        let source: RhythmPlayer.Source
        let chart: (RhythmSong.Difficulty) -> [RhythmSong.ChartNote]
    }

    /// The song playing in Rhythm.
    private(set) var rhythmTrack: RhythmTrack?

    @ObservationIgnored private let library: RhythmLibrary

    init(walker: FriendWalker, pet: PetStateMachine, hotkey: ExplainHotkey, library: RhythmLibrary) {
        self.library = library
        self.walker = walker
        self.pet = pet
        self.hotkey = hotkey
        fastLane.onInput = { [weak self] steer, jump, drop in
            self?.steer = steer
            self?.jump = jump
            self?.drop = drop
            self?.lastTilt = .now
            self?.lastFastTilt = .now
        }
    }

    func handle(_ message: CatchMessage) {
        switch message {
        case .start(let mode, let pick): begin(mode, pick)
        case .lane(let touch): play(touch)
        case .ping(let sent): send(.pong(sent: sent, mac: RhythmPlayer.now))
        case .calibrate where phase != .playing: playClicks()
        case .input(let value, let jump, let drop) where value.isFinite && Date.now.timeIntervalSince(lastFastTilt) > Self.tiltTimeout:
            steer = max(-1, min(1, value))
            self.jump = jump
            self.drop = drop
            lastTilt = .now
        case .pause where phase == .playing: pause()
        case .resume where phase == .paused:
            if let track = rhythmTrack, !player.play(track.source, from: pausedAt) { return end() }
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
        send(.songs(library.songs))
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
        rhythm = nil
        rhythmPick = nil
        player.stop()
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

    private func begin(_ mode: MacGame, _ pick: RhythmPick?) {
        let track = pick.flatMap { rhythmTrack(id: $0.song) }
        guard mode != .rhythm || track != nil else { return phase == .off ? send(.quit) : () } // an unknown song: ignore it
        player.stop()
        // The song first: if the sounds can't play, nothing has been put on screen yet.
        if mode == .rhythm, let track, !player.play(track.source) { return phase == .off ? send(.quit) : end() }
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
        best = UserDefaults.standard.integer(forKey: Self.bestKey(mode, pick))
        game = mode == .catchFood ? CatchGame(width: field.width, height: field.height) : nil
        runner = nil
        rhythm = nil
        rhythmPick = nil
        rhythmTrack = track
        if mode == .rhythm, let track, let pick {
            rhythm = RhythmJudge(notes: track.chart(pick.difficulty))
            rhythmPick = RhythmPick(song: pick.song, difficulty: pick.difficulty, calibration: max(0, min(0.4, pick.calibration)))
            songTime = -rhythmPick!.calibration
            // Beside the hit line, left of the highway.
            let size = field.size, spot = CGPoint(x: field.minX + RhythmStage.highway(in: size).minX - 70,
                                                  y: field.maxY - RhythmStage.hitY(in: size))
            walker.run(to: spot, steer: 1) // faces the highway…
            walker.run(to: spot, steer: 0) // …and stands still
        }
        if mode == .runner {
            runner = RunnerGame(width: field.width, height: field.height)
            if !CGPreflightScreenCaptureAccess() { CGRequestScreenCaptureAccess() } // asks once; Explain uses it too
            readWords()
        }
        phase = .playing
        steer = 0
        jump = false
        drop = false
        pops = []
        idleSince = nil
        lastTick = .now
        publish()
    }

    private func pause() {
        if rhythm != nil {
            pausedAt = player.stop()
            // The phone's lanes vanish without a release: let go here, so a hold can't finish while nobody holds it.
            judged((0..<RhythmSong.lanes).flatMap { rhythm!.release(lane: $0, at: pausedAt - (rhythmPick?.calibration ?? 0)) })
        }
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
        if now.timeIntervalSince(lastTilt) > Self.tiltTimeout { (steer, jump, drop) = (0, false, false) }
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
            if now.timeIntervalSince(wordsReadAt) > Self.wordReadInterval { readWords() }
            let events = runner.step(dt: dt, steer: steer, jump: jump, drop: drop, using: &rng)
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
        } else if rhythm != nil, let time = player.time {
            songTime = time - (rhythmPick?.calibration ?? 0)
            judged(rhythm!.advance(to: songTime))
        }
    }

    // MARK: Rhythm

    private func rhythmTrack(id: String) -> RhythmTrack? {
        if let song = RhythmSong.named(id) { return RhythmTrack(title: song.title, source: .song(song), chart: song.chart) }
        guard let entry = library.entry(id) else { return nil }
        let url = library.url(of: entry)
        return RhythmTrack(title: entry.title, source: entry.kind == .midi ? .midi(url) : .audio(url), chart: entry.chart)
    }

    /// A lane pressed or let go on the phone, judged at the moment it happened in the song (as the player heard it).
    private func play(_ touch: RhythmTouch) {
        guard phase == .playing, var judge = rhythm, let startedAt = player.startedAt, touch.at.isFinite else { return }
        let time = touch.at - startedAt - (rhythmPick?.calibration ?? 0)
        let events = touch.down ? judge.press(lane: touch.lane, at: time) : judge.release(lane: touch.lane, at: time)
        rhythm = judge
        judged(events)
    }

    private func judged(_ events: [RhythmJudge.Event]) {
        guard let judge = rhythm, !events.isEmpty else { return }
        let size = field.size, hit = RhythmStage.hitY(in: size)
        for event in events {
            switch event {
            case .judged(let index, let judgement):
                pops.append(Pop(text: judgement.title, x: RhythmStage.laneX(judge.notes[index].lane, in: size), y: hit - 30, at: .now))
                if judgement == .miss { react(.cry, .concerned) } else { send(.hit(.food)); react(.cheer, .excited) }
            case .broke(let index):
                pops.append(Pop(text: "Let go", x: RhythmStage.laneX(judge.notes[index].lane, in: size), y: hit - 30, at: .now))
            case .held(let index):
                pops.append(Pop(text: "+100", x: RhythmStage.laneX(judge.notes[index].lane, in: size), y: hit - 30, at: .now))
            case .failed, .finished:
                player.stop()
                over(score: judge.score)
            }
        }
        publish()
    }

    private func react(_ action: PetAction, _ mood: PetMood) {
        guard Date.now.timeIntervalSince(reactedAt) > Self.reactionInterval else { return }
        reactedAt = .now
        pet.apply(PetReaction(action: action, mood: mood, dialogue: ""))
    }

    /// The phone's tap-along calibration: eight clicks, and when each plays on this clock.
    private func playClicks() {
        let song = RhythmSong.clicks
        guard player.play(.song(song)), let startedAt = player.startedAt else { return }
        send(.clicks(song.parts[0].notes.map { startedAt + song.seconds($0.beat) }))
        clicksDone?.cancel() // a second calibration keeps its own clicks
        clicksDone = Task { [weak self] in
            try? await Task.sleep(for: .seconds(song.duration + 0.5))
            guard !Task.isCancelled, let self, self.phase != .playing else { return } // a song started meanwhile keeps playing
            self.player.stop()
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
        UserDefaults.standard.set(best, forKey: Self.bestKey(mode, rhythmPick))
    }

    private func publish() {
        if let judge = rhythm {
            let status = RhythmStatus(health: judge.health, combo: judge.combo, accuracy: judge.accuracy, grade: judge.grade, failed: judge.failed)
            return send(.state(CatchStatus(score: judge.score, lives: 0, best: max(best, judge.score),
                                           paused: phase == .paused, over: phase == .over, rhythm: status)))
        }
        guard let (score, lives) = game.map({ ($0.score, $0.lives) }) ?? runner.map({ ($0.score, $0.lives) }) else { return }
        send(.state(CatchStatus(score: score, lives: lives, best: max(best, score),
                                paused: phase == .paused, over: phase == .over)))
    }

    /// Reads the words on the friend's display in the background; the level changes when they arrive.
    private func readWords() {
        guard !readingWords, let screen = walker.panel?.characterScreen ?? NSScreen.main else { return }
        readingWords = true
        wordsReadAt = .now
        let field = field
        Task { [weak self] in
            let words = await ScreenWords.read(field, on: screen)
            guard let self else { return }
            self.readingWords = false
            self.wordsBlocked = words == nil
            guard self.phase != .off, self.field == field, var runner = self.runner else { return }
            runner.setWords(words ?? [])
            self.runner = runner
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
                if let judge = session.rhythm { RhythmStage.draw(judge, at: session.songTime, in: context, size: size) }
                for pop in session.pops {
                    let age = Date.now.timeIntervalSince(pop.at)
                    var faded = context
                    faded.opacity = max(0, 1 - age / 0.8)
                    faded.draw(Text(pop.text).font(.title.bold()).foregroundStyle(.white),
                               at: CGPoint(x: pop.x, y: pop.y - 30 - age * 60))
                }
            }
            if let (score, lives) = session.game.map({ ($0.score, $0.lives) }) ?? session.runner.map({ ($0.score, $0.lives) })
                ?? session.rhythm.map({ ($0.score, -1) }) {
                header(score: score, lives: lives)
            }
        }
        .ignoresSafeArea()
    }

    /// The words' tops glow faintly so you can see what's solid; clouds, coins and the lava are drawn.
    private func drawRunner(_ runner: RunnerGame, in context: GraphicsContext, size: CGSize) {
        for ledge in runner.ledges {
            let edge = CGRect(x: ledge.minX, y: ledge.y - 2, width: ledge.maxX - ledge.minX, height: 4)
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
                if lives >= 0 { // Rhythm has a health bar instead
                    Text(String(repeating: "❤️", count: lives) + String(repeating: "🤍", count: max(0, CatchGame.startLives - lives)))
                } else if let track = session.rhythmTrack {
                    Text(track.title)
                }
                Text("\(score)").monospacedDigit()
                Text("Best \(max(session.best, score))").foregroundStyle(.secondary)
            }
            .font(.title2.bold())
            switch session.phase {
            case .paused: Text("Paused · resume on your iPhone, Esc ends").font(.headline)
            case .playing where session.runner != nil && session.wordsBlocked:
                Text("Allow befriend in Screen Recording (System Settings) to stand on your screen's words").font(.headline)
            case .over:
                if let judge = session.rhythm {
                    Text(judge.failed ? "Failed · try again on your iPhone, Esc ends"
                         : "Grade \(judge.grade) · \(Int((judge.accuracy * 100).rounded()))% · play again on your iPhone, Esc ends").font(.headline)
                } else {
                    Text("Game over · play again on your iPhone, Esc ends").font(.headline)
                }
            default: EmptyView()
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 10)
        .background(.regularMaterial, in: .rect(cornerRadius: 14))
        .padding(.top, 16)
    }
}
