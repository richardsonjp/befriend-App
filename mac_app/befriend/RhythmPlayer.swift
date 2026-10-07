//
//  RhythmPlayer.swift
//  befriend
//
//  Rhythm (M43): plays a `RhythmSong` through the General MIDI instruments macOS ships, one sampler per part, timed by
//  `AVAudioSequencer` (sample-accurate, unlike a timer). `startedAt` maps song time to the clock the phone syncs to.
//

import AVFoundation
import AudioToolbox
import os
import PetCore

@MainActor
final class RhythmPlayer {
    private static let soundBank = URL(fileURLWithPath: "/System/Library/Components/CoreAudio.component/Contents/Resources/gs_instruments.dls")
    private static let log = Logger(subsystem: "com.richardsonjp.befriend", category: "rhythm")

    /// `systemUptime` when the song's second 0 plays; nil when stopped.
    private(set) var startedAt: TimeInterval?
    private var engine: AVAudioEngine?
    private var sequencer: AVAudioSequencer?

    static var now: TimeInterval { ProcessInfo.processInfo.systemUptime }

    /// Seconds into the song, while playing.
    var time: Double? { startedAt.map { Self.now - $0 } }

    /// False when the sounds or the engine can't start (the game then can't run).
    @discardableResult
    func play(_ song: RhythmSong, from seconds: Double = 0) -> Bool {
        stop()
        guard let data = Self.midi(song) else { return false }
        let engine = AVAudioEngine()
        do {
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
            return true
        } catch {
            Self.log.error("Couldn't play \(song.id, privacy: .public): \(error.localizedDescription, privacy: .public)")
            engine.stop()
            return false
        }
    }

    /// Stops and returns where it was, to resume from.
    @discardableResult
    func stop() -> Double {
        let position = time ?? 0
        sequencer?.stop()
        engine?.stop()
        sequencer = nil
        engine = nil
        startedAt = nil
        return position
    }

    /// The song as a Standard MIDI File: a tempo track, then one track per part (drums on channel 10).
    private static func midi(_ song: RhythmSong) -> Data? {
        var made: MusicSequence?
        guard NewMusicSequence(&made) == noErr, let sequence = made else { return nil }
        defer { DisposeMusicSequence(sequence) }
        var tempo: MusicTrack?
        MusicSequenceGetTempoTrack(sequence, &tempo)
        if let tempo { MusicTrackNewExtendedTempoEvent(tempo, 0, song.bpm) }
        for (index, part) in song.parts.enumerated() {
            var made: MusicTrack?
            guard MusicSequenceNewTrack(sequence, &made) == noErr, let track = made else { return nil }
            let channel = UInt8(part.drums ? 9 : index)
            for note in part.notes {
                var message = MIDINoteMessage(channel: channel, note: note.pitch, velocity: note.velocity,
                                              releaseVelocity: 0, duration: Float32(note.length))
                MusicTrackNewMIDINoteEvent(track, note.beat, &message)
            }
        }
        var data: Unmanaged<CFData>?
        guard MusicSequenceFileCreateData(sequence, .midiType, .eraseFile, 480, &data) == noErr else { return nil }
        return data?.takeRetainedValue() as Data?
    }
}
