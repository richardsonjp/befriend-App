//
//  RhythmMIDI.swift
//  PetCore
//
//  Rhythm (M43) and MIDI: a song written out as a Standard MIDI File (the built-in songs play this way), and a MIDI
//  file read back as a song whose melody makes the chart (the user's own .mid files).
//

import AudioToolbox
import Foundation

public extension RhythmSong {
    enum MIDIFailure: LocalizedError {
        case unreadable
        case noMelody

        public var errorDescription: String? {
            self == .unreadable ? "That MIDI file couldn't be read." : "That MIDI file has no notes to play along to."
        }
    }

    /// The song as a Standard MIDI File: a tempo track, then one track per part (drums on channel 10).
    func midiData() -> Data? {
        var made: MusicSequence?
        guard NewMusicSequence(&made) == noErr, let sequence = made else { return nil }
        defer { DisposeMusicSequence(sequence) }
        var tempo: MusicTrack?
        MusicSequenceGetTempoTrack(sequence, &tempo)
        if let tempo { MusicTrackNewExtendedTempoEvent(tempo, 0, bpm) }
        for (index, part) in parts.enumerated() {
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

    /// A MIDI file as a song: one part per channel (channel 10 is drums), the melody first. The melody is the
    /// highest-sounding channel among the busy ones (at least a third as many notes as the busiest).
    static func load(midi data: Data, id: String, title: String) throws -> RhythmSong {
        var made: MusicSequence?
        guard NewMusicSequence(&made) == noErr, let sequence = made,
              MusicSequenceFileLoadData(sequence, data as CFData, .midiType, []) == noErr else { throw MIDIFailure.unreadable }
        defer { DisposeMusicSequence(sequence) }
        var tempos: [Tempo] = [] // every change, so the chart follows the tempo the file really plays at
        var tempo: MusicTrack?
        MusicSequenceGetTempoTrack(sequence, &tempo)
        if let tempo {
            events(in: tempo) { type, data, beat in
                guard type == kMusicEventType_ExtendedTempo else { return }
                let bpm = data.assumingMemoryBound(to: ExtendedTempoEvent.self).pointee.bpm
                if bpm > 0 { tempos.append(Tempo(beat: beat, bpm: bpm)) }
            }
        }
        let bpm = tempos.first?.beat == 0 ? tempos[0].bpm : 120 // MIDI's default until the first change
        var channels: [UInt8: [Note]] = [:]
        var tracks: UInt32 = 0
        MusicSequenceGetTrackCount(sequence, &tracks)
        for index in 0..<tracks {
            var track: MusicTrack?
            guard MusicSequenceGetIndTrack(sequence, index, &track) == noErr, let track else { continue }
            events(in: track) { type, data, beat in
                guard type == kMusicEventType_MIDINoteMessage else { return }
                let message = data.assumingMemoryBound(to: MIDINoteMessage.self).pointee
                guard message.velocity > 0 else { return }
                channels[message.channel & 0x0F, default: []].append(
                    Note(beat: beat, length: Double(message.duration), pitch: message.note, velocity: message.velocity))
            }
        }
        let melodic = channels.filter { $0.key != 9 }
        let busiest = melodic.values.map(\.count).max() ?? 0
        guard busiest > 0, let melody = melodic.filter({ $0.value.count * 3 >= busiest })
            .max(by: { average($0.value) < average($1.value) })?.key else { throw MIDIFailure.noMelody }
        let order = [melody] + channels.keys.filter { $0 != melody }.sorted()
        return RhythmSong(id: id, title: title, bpm: bpm, parts: order.map {
            Part(program: 0, drums: $0 == 9, notes: channels[$0] ?? [])
        }, tempos: tempos)
    }

    private static func average(_ notes: [Note]) -> Double {
        notes.map { Double($0.pitch) }.reduce(0, +) / Double(max(1, notes.count))
    }

    private static func events(in track: MusicTrack, _ visit: (MusicEventType, UnsafeRawPointer, Double) -> Void) {
        var made: MusicEventIterator?
        guard NewMusicEventIterator(track, &made) == noErr, let iterator = made else { return }
        defer { DisposeMusicEventIterator(iterator) }
        var hasEvent: DarwinBoolean = false
        MusicEventIteratorHasCurrentEvent(iterator, &hasEvent)
        while hasEvent.boolValue {
            var beat: MusicTimeStamp = 0
            var type: MusicEventType = 0
            var data: UnsafeRawPointer?
            var size: UInt32 = 0
            MusicEventIteratorGetEventInfo(iterator, &beat, &type, &data, &size)
            if let data { visit(type, data, beat) }
            MusicEventIteratorNextEvent(iterator)
            MusicEventIteratorHasCurrentEvent(iterator, &hasEvent)
        }
    }
}
