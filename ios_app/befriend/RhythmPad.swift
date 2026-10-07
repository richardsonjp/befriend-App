//
//  RhythmPad.swift
//  befriend
//
//  Rhythm (M43) on the iPhone: four lanes to tap and hold, the song and difficulty, and the timing that makes it fair.
//  Every press is stamped on the Mac's clock (synced by a few pings) so network delay doesn't count, and a tap-along
//  calibration measures how late this player hears the Mac (speakers vs AirPods).
//

import Observation
import PetCore
import SwiftUI

@MainActor @Observable
final class RhythmPad {
    struct TapAlong {
        var clicks: [Double] = []
        var taps: [Double] = []
    }

    private static let calibrationKey = "rhythm.calibration"
    private static let pings = 8

    var song = RhythmSong.all[0].id
    var difficulty = RhythmSong.Difficulty.easy
    /// Seconds this player taps late to what they hear; 0 until calibrated.
    private(set) var calibration = UserDefaults.standard.double(forKey: RhythmPad.calibrationKey)
    private(set) var pressed: Set<Int> = []
    /// Calibrating: the clicks' times (once the Mac says) and the taps so far.
    private(set) var tapAlong: TapAlong?
    private(set) var calibrationNote: String?

    @ObservationIgnored var send: (CatchMessage) -> Void = { _ in }
    @ObservationIgnored private var samples: [(sent: Double, theirs: Double, received: Double)] = []
    @ObservationIgnored private var offset: Double?
    @ObservationIgnored private var finishing: Task<Void, Never>?

    private static var now: Double { ProcessInfo.processInfo.systemUptime }

    var pick: RhythmPick { RhythmPick(song: song, difficulty: difficulty, calibration: calibration) }

    /// A few pings, before the Mac gets busy starting a song; the quickest round trip sets the offset to its clock.
    func syncClock() async {
        samples = []
        for _ in 0..<Self.pings {
            send(.ping(Self.now))
            try? await Task.sleep(for: .milliseconds(60))
        }
        try? await Task.sleep(for: .milliseconds(150)) // the last pongs
    }

    func pong(sent: Double, mac: Double) {
        samples.append((sent, mac, Self.now))
        offset = RhythmJudge.clockOffset(samples)
    }

    func lane(_ lane: Int, down: Bool) {
        guard let offset, down != pressed.contains(lane) else { return }
        if down { pressed.insert(lane) } else { pressed.remove(lane) }
        send(.lane(RhythmTouch(lane: lane, down: down, at: Self.now + offset)))
    }

    /// The lanes vanished under the fingers (paused, over, closed): no end comes, so forget them.
    func releaseAll() { pressed = [] }

    // MARK: Calibration

    func startCalibration() {
        tapAlong = TapAlong()
        calibrationNote = nil
        finishing?.cancel()
        Task {
            await syncClock()
            send(.calibrate)
        }
        finishing = Task { [weak self] in // the Mac never answered
            try? await Task.sleep(for: .seconds(5))
            guard !Task.isCancelled else { return }
            guard let self, self.tapAlong?.clicks.isEmpty == true else { return }
            self.tapAlong = nil
            self.calibrationNote = "Your Mac didn't play the clicks. Try again."
        }
    }

    func clicks(_ times: [Double]) {
        guard tapAlong != nil, let last = times.last else { return }
        tapAlong?.clicks = times
        let wait = offset.map { last - (Self.now + $0) } ?? 6
        finishing?.cancel()
        finishing = Task { [weak self] in
            try? await Task.sleep(for: .seconds(max(0, wait) + 1))
            guard !Task.isCancelled else { return }
            self?.finishCalibration()
        }
    }

    func tap() {
        guard let offset, tapAlong != nil else { return }
        tapAlong?.taps.append(Self.now + offset)
    }

    func cancelCalibration() {
        finishing?.cancel()
        tapAlong = nil
    }

    private func finishCalibration() {
        guard let tapAlong else { return }
        self.tapAlong = nil
        guard let measured = RhythmJudge.calibration(taps: tapAlong.taps, clicks: tapAlong.clicks) else {
            calibrationNote = "Not enough taps. Tap once on every click."
            return
        }
        calibration = measured
        UserDefaults.standard.set(measured, forKey: Self.calibrationKey)
        calibrationNote = "Timing set: \(Int((measured * 1000).rounded())) ms"
    }
}

// MARK: Views

/// Song, difficulty and timing, on the Ready screen.
struct RhythmSetup: View {
    @Bindable var rhythm: RhythmPad

    var body: some View {
        VStack(spacing: 12) {
            Picker("Song", selection: $rhythm.song) {
                ForEach(RhythmSong.all) { song in Text("\(song.title) · \(Int(song.bpm)) bpm").tag(song.id) }
            }
            .pickerStyle(.menu)
            Picker("Difficulty", selection: $rhythm.difficulty) {
                ForEach(RhythmSong.Difficulty.allCases, id: \.self) { Text($0.title) }
            }
            .pickerStyle(.segmented)
            .frame(maxWidth: 220)
            HStack {
                Text("Timing \(Int((rhythm.calibration * 1000).rounded())) ms").monospacedDigit().foregroundStyle(.secondary)
                Button("Calibrate", action: rhythm.startCalibration).buttonStyle(.bordered)
            }
            if let note = rhythm.calibrationNote { Text(note).font(.footnote).foregroundStyle(.secondary) }
        }
    }
}

/// Tap once on each of the eight clicks your Mac plays.
struct RhythmTapAlong: View {
    let rhythm: RhythmPad
    @State private var touching = false

    var body: some View {
        VStack(spacing: 16) {
            Text("Tap along").font(.title.bold())
            Text("Your Mac plays eight clicks. Tap the pad once on each, in time with what you hear.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
            RoundedRectangle(cornerRadius: 24)
                .fill(.tint.opacity(0.3))
                .overlay { Text("\(rhythm.tapAlong?.taps.count ?? 0)").font(.system(size: 56, weight: .bold)).monospacedDigit() }
                .frame(height: 180)
                .contentShape(.rect)
                .gesture(DragGesture(minimumDistance: 0) // on touch-down, as the lanes judge, not on lift
                    .onChanged { _ in
                        if !touching { rhythm.tap() }
                        touching = true
                    }
                    .onEnded { _ in touching = false })
                .accessibilityAddTraits(.isButton)
                .accessibilityLabel("Tap on each click")
            Button("Cancel", action: rhythm.cancelCalibration)
        }
    }
}

/// Four lanes, the Mac's colours left to right. Each is its own touch, so chords and holds work.
struct RhythmLanes: View {
    let rhythm: RhythmPad
    private static let colors: [Color] = [.green, .red, .yellow, .blue]

    var body: some View {
        HStack(spacing: 8) {
            ForEach(0..<RhythmSong.lanes, id: \.self) { lane in
                RoundedRectangle(cornerRadius: 18)
                    .fill(Self.colors[lane].opacity(rhythm.pressed.contains(lane) ? 0.95 : 0.35))
                    .contentShape(.rect)
                    .gesture(DragGesture(minimumDistance: 0)
                        .onChanged { _ in rhythm.lane(lane, down: true) }
                        .onEnded { _ in rhythm.lane(lane, down: false) })
                    .accessibilityElement()
                    .accessibilityLabel("Lane \(lane + 1)")
                    .accessibilityAddTraits(.isButton)
            }
        }
    }
}

struct RhythmHealth: View {
    let status: RhythmStatus

    var body: some View {
        VStack(spacing: 6) {
            ProgressView(value: status.health).tint(status.health > 0.3 ? .green : .red).frame(maxWidth: 220)
            if status.combo >= 5 { Text("\(status.combo) combo").font(.headline) }
        }
    }
}
