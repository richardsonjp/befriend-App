//
//  RhythmSongsView.swift
//  befriend
//
//  Rhythm (M43): add your own songs (audio or MIDI) to play on the iPhone's lanes, and remove them.
//

import AppKit
import PetCore
import SwiftUI
import UniformTypeIdentifiers

struct RhythmSongsView: View {
    let library: RhythmLibrary

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Songs you add show up in Rhythm on your iPhone. befriend listens to each one once, here on your Mac, to write its notes. Clear, punchy songs make the best charts; MIDI files chart exactly.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            List {
                ForEach(library.entries) { entry in
                    HStack {
                        Image(systemName: entry.kind == .midi ? "pianokeys" : "waveform")
                        VStack(alignment: .leading) {
                            Text(entry.title)
                            Text("\(Int(entry.bpm)) bpm · \(Self.time(entry.duration)) · \(entry.easy.count) / \(entry.hard.count) notes")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Remove", systemImage: "trash") { library.remove(entry) }
                            .labelStyle(.iconOnly)
                            .buttonStyle(.borderless)
                    }
                }
                ForEach(library.adding) { pending in
                    HStack {
                        ProgressView().controlSize(.small)
                        Text("Listening to \(pending.title)…").foregroundStyle(.secondary)
                    }
                }
            }
            .overlay {
                if library.entries.isEmpty && library.adding.isEmpty {
                    ContentUnavailableView("No songs yet", systemImage: "music.note", description: Text("MP3, M4A, WAV, AIFF or MIDI"))
                }
            }
            ForEach(library.failures) { Text("\($0.title): \($0.message ?? "")").font(.callout).foregroundStyle(.red) }
            Button("Add Songs…", systemImage: "plus", action: pick)
        }
        .padding(16)
        .frame(minWidth: 420, minHeight: 360)
    }

    private func pick() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = [.audio, .midi]
        panel.message = "Choose songs to play in Rhythm"
        guard panel.runModal() == .OK else { return }
        library.add(panel.urls)
    }

    private static func time(_ seconds: Double) -> String {
        let whole = Int(seconds.rounded())
        return "\(whole / 60):\(String(format: "%02d", whole % 60))"
    }
}
