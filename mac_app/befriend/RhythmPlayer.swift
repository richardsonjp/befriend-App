//
//  RhythmPlayer.swift
//  befriend
//
//  Rhythm (M43): plays a song and says where it is. Built-in songs play through the General MIDI instruments macOS
//  ships, one sampler per part, timed by `AVAudioSequencer`; added MIDI files through `AVMIDIPlayer` with the same
//  sounds; added recordings through `AVAudioPlayer`. Added songs get a 2 s lead-in, since their notes can start at
//  once. `startedAt` maps song time to the clock the phone syncs to.
//

import AVFoundation
import AudioToolbox
import os
import PetCore

@MainActor
final class RhythmPlayer {
    enum Source {
        case song(RhythmSong)
        case midi(URL)
        case audio(URL)
    }

    private static let soundBank = URL(fileURLWithPath: "/System/Library/Components/CoreAudio.component/Contents/Resources/gs_instruments.dls")
    private static let log = Logger(subsystem: "com.richardsonjp.befriend", category: "rhythm")
    /// Time for the first notes to fall into view before an added song begins.
    private static let leadIn = 2.0

    /// `systemUptime` when the song's second 0 plays (later than now during a lead-in); nil when stopped.
    private(set) var startedAt: TimeInterval?
    private var engine: AVAudioEngine?
    private var sequencer: AVAudioSequencer?
    private var midiPlayer: AVMIDIPlayer?
    private var audioPlayer: AVAudioPlayer?
    private var pendingStart: Task<Void, Never>?

    static var now: TimeInterval { ProcessInfo.processInfo.systemUptime }

    /// Seconds into the song (negative during a lead-in), while playing.
    var time: Double? { startedAt.map { Self.now - $0 } }

    /// False when the sounds or the file can't play (the game then can't run).
    @discardableResult
    func play(_ source: Source, from seconds: Double = 0) -> Bool {
        stop()
        let lead = seconds > 0 ? 0 : Self.leadIn
        do {
            switch source {
            case .song(let song):
                try playSong(song, from: seconds)
            case .audio(let url):
                let player = try AVAudioPlayer(contentsOf: url)
                player.prepareToPlay()
                player.currentTime = seconds
                guard player.play(atTime: player.deviceCurrentTime + lead) else { return false }
                startedAt = Self.now + lead - seconds
                audioPlayer = player
            case .midi(let url):
                let player = try AVMIDIPlayer(contentsOf: url, soundBankURL: Self.soundBank)
                player.prepareToPlay()
                player.currentPosition = seconds
                startedAt = Self.now + lead - seconds
                midiPlayer = player
                pendingStart = Task { [weak self] in
                    try? await Task.sleep(for: .seconds(lead))
                    guard !Task.isCancelled, let self, self.midiPlayer === player else { return }
                    player.play(nil) // not the async form: that waits for the end
                    // When it really began, unless the player's position isn't settled yet (then keep the plan).
                    let actual = Self.now - player.currentPosition
                    if let planned = self.startedAt, abs(actual - planned) < 0.1 { self.startedAt = actual }
                }
            }
            return true
        } catch {
            Self.log.error("Couldn't play: \(error.localizedDescription, privacy: .public)")
            stop()
            return false
        }
    }

    /// Stops and returns where it was, to resume from.
    @discardableResult
    func stop() -> Double {
        let position = max(0, time ?? 0)
        pendingStart?.cancel()
        pendingStart = nil
        sequencer?.stop()
        engine?.stop()
        midiPlayer?.stop()
        audioPlayer?.stop()
        sequencer = nil
        engine = nil
        midiPlayer = nil
        audioPlayer = nil
        startedAt = nil
        return position
    }

    private func playSong(_ song: RhythmSong, from seconds: Double) throws {
        guard let data = song.midiData() else { throw CocoaError(.fileReadCorruptFile) }
        let engine = AVAudioEngine()
        var samplers: [AVAudioUnitSampler] = []
        for part in song.parts {
            let sampler = AVAudioUnitSampler()
            engine.attach(sampler)
            engine.connect(sampler, to: engine.mainMixerNode, format: nil)
            try sampler.loadSoundBankInstrument(
                at: Self.soundBank, program: part.drums ? 0 : part.program,
                bankMSB: UInt8(part.drums ? kAUSampler_DefaultPercussionBankMSB : kAUSampler_DefaultMelodicBankMSB),
                bankLSB: UInt8(kAUSampler_DefaultBankLSB))
            samplers.append(sampler)
        }
        let sequencer = AVAudioSequencer(audioEngine: engine)
        try sequencer.load(from: data, options: [])
        for (track, sampler) in zip(sequencer.tracks, samplers) { track.destinationAudioUnit = sampler }
        try engine.start()
        sequencer.prepareToPlay()
        sequencer.currentPositionInSeconds = seconds
        try sequencer.start()
        startedAt = Self.now - seconds
        self.engine = engine
        self.sequencer = sequencer
    }
}
