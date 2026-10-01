//
//  TimelapseViews.swift
//  PetCore
//

import AVFoundation
import AVKit
import SwiftUI

/// The timelapses kept on this device (M13), as a square 3-column grid like a photo profile — up to 3 rows at the 9
/// kept (M15): the iPhone's Timelapses page and the Mac's window. Tap plays; the context menu (VoiceOver: actions)
/// shares, shows in Finder on the Mac, or deletes after asking.
public struct TimelapseGallery: View {
    let library: TimelapseLibrary
    /// The Mac's "Show in Finder"; nil on iPhone.
    let reveal: ((URL) -> Void)?
    @State private var playing: Timelapse?
    @State private var deleting: Timelapse?

    private static let columns = Array(repeating: GridItem(.flexible(), spacing: 2), count: 3)

    public init(library: TimelapseLibrary, reveal: ((URL) -> Void)? = nil) {
        self.library = library
        self.reveal = reveal
    }

    public var body: some View {
        Group {
            if library.videos.isEmpty {
                ContentUnavailableView(
                    "No timelapses yet", systemImage: "film.stack",
                    description: Text("Turn on “Record a timelapse” in the focus card. Each focus becomes a 1-minute video here.")
                )
            } else {
                ScrollView {
                    LazyVGrid(columns: Self.columns, spacing: 2) {
                        ForEach(library.videos) { timelapse in
                            if let video = timelapse.video { tile(timelapse, video) }
                        }
                    }
                    Text("\(library.videos.count) of \(TimelapseLibrary.keep) kept · "
                         + ByteCountFormatter.string(fromByteCount: Int64(library.totalBytes), countStyle: .file)
                         + " · only on this device. The oldest is removed when a new one is saved.")
                        .font(.footnote).foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding()
                }
            }
        }
        .sheet(item: $playing) { timelapse in
            if let video = timelapse.video { TimelapsePlayer(timelapse: timelapse, video: video) }
        }
        .confirmationDialog("Delete this timelapse?", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
                            titleVisibility: .visible, presenting: deleting) { timelapse in
            Button("Delete", role: .destructive) { library.delete(timelapse) }
        } message: { _ in
            Text("It's only on this device, so it can't be recovered.")
        }
    }

    private func tile(_ timelapse: Timelapse, _ video: URL) -> some View {
        Button { playing = timelapse } label: {
            Thumbnail(url: video)
                .overlay {
                    Image(systemName: "play.fill")
                        .font(.title3)
                        .foregroundStyle(.white)
                        .shadow(radius: 3)
                }
                .overlay(alignment: .bottomLeading) {
                    VStack(alignment: .leading, spacing: 0) {
                        Text(timelapse.title ?? timelapse.startedAt.formatted(.dateTime.day().month(.abbreviated).hour().minute()))
                            .font(.caption2.weight(.semibold))
                            .lineLimit(1)
                        Text("\(Self.minutes(timelapse)) min → 1:00").font(.caption2)
                    }
                    .foregroundStyle(.white)
                    .padding(6)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(LinearGradient(colors: [.clear, .black.opacity(0.6)], startPoint: .top, endPoint: .bottom))
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu { menu(timelapse, video) }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(timelapse.title.map { $0 + ", " } ?? "")focus on \(timelapse.startedAt.formatted(date: .long, time: .shortened)), \(Self.minutes(timelapse)) minutes, a 1-minute video")
        .accessibilityHint("Plays the timelapse")
        .accessibilityAddTraits(.isButton)
        .accessibilityAction(named: "Delete") { deleting = timelapse }
        .accessibilityActions {
            if let reveal { Button("Show in Finder") { reveal(video) } }
        }
    }

    @ViewBuilder
    private func menu(_ timelapse: Timelapse, _ video: URL) -> some View {
        ShareLink(item: video) { Label("Share or Save", systemImage: "square.and.arrow.up") }
        if let reveal {
            Button { reveal(video) } label: { Label("Show in Finder", systemImage: "folder") }
        }
        Button(role: .destructive) { deleting = timelapse } label: { Label("Delete", systemImage: "trash") }
    }

    static func minutes(_ timelapse: Timelapse) -> Int {
        max(1, Int((timelapse.recordedSeconds / 60).rounded()))
    }
}

/// One timelapse, large, with a way out (Close or Esc), Save As… on the Mac, and Share.
struct TimelapsePlayer: View {
    let timelapse: Timelapse
    let video: URL
    @State private var player: AVPlayer
    @State private var shape: CGSize?
    @State private var saveError: String?
    @Environment(\.dismiss) private var dismiss

    init(timelapse: Timelapse, video: URL) {
        self.timelapse = timelapse
        self.video = video
        _player = State(initialValue: AVPlayer(url: video))
    }

    var body: some View {
        NavigationStack {
            VideoPlayer(player: player)
                .aspectRatio(shape.map { $0.width / $0.height } ?? 9 / 16, contentMode: .fit)
                .frame(idealWidth: ideal.width, idealHeight: ideal.height)
                .navigationTitle(timelapse.title ?? timelapse.startedAt.formatted(date: .abbreviated, time: .shortened))
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Close") { dismiss() }.keyboardShortcut(.cancelAction)
                    }
                    #if os(macOS)
                    ToolbarItem(placement: .primaryAction) {
                        Button("Save As…", systemImage: "square.and.arrow.down", action: saveAs)
                            .keyboardShortcut("s")
                    }
                    #endif
                    ToolbarItem(placement: .primaryAction) {
                        ShareLink(item: video)
                    }
                }
        }
        .task {
            if let track = try? await AVURLAsset(url: video).loadTracks(withMediaType: .video).first,
               let size = try? await track.load(.naturalSize), size.width > 0, size.height > 0 {
                shape = size
            }
            player.play()
        }
        .onDisappear { player.pause() }
        .alert("Couldn't save the video", isPresented: Binding(get: { saveError != nil }, set: { if !$0 { saveError = nil } })) {
            Button("OK") {}
        } message: {
            Text(saveError ?? "")
        }
    }

    /// Portrait or landscape at a comfortable size (the Mac's sheet sizes itself from this).
    private var ideal: CGSize {
        guard let shape, shape.width > shape.height else { return CGSize(width: 405, height: 720) }
        return CGSize(width: 800, height: 450)
    }

    #if os(macOS)
    /// The standard save panel, starting in Downloads; the original stays in befriend.
    private func saveAs() {
        let panel = NSSavePanel()
        panel.directoryURL = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
        panel.allowedContentTypes = [.mpeg4Movie]
        panel.nameFieldStringValue = "befriend focus \(Self.fileDate.string(from: timelapse.startedAt)).mp4"
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) } // the panel asked
            try FileManager.default.copyItem(at: video, to: url)
        } catch {
            saveError = error.localizedDescription
        }
    }

    private static let fileDate: DateFormatter = {
        let format = DateFormatter()
        format.locale = Locale(identifier: "en_US_POSIX")
        format.dateFormat = "yyyy-MM-dd HH.mm"
        return format
    }()
    #endif
}

/// A square still from the middle of the video, filling its tile.
private struct Thumbnail: View {
    let url: URL
    @State private var image: CGImage?

    var body: some View {
        Rectangle()
            .fill(.quaternary)
            .aspectRatio(1, contentMode: .fit)
            .overlay {
                if let image {
                    Image(decorative: image, scale: 1).resizable().scaledToFill()
                }
            }
            .clipped()
            .task(id: url) { image = await Self.still(url) }
    }

    // ponytail: regenerated each time a tile appears; the library keeps 9, so no cache.
    private static func still(_ url: URL) async -> CGImage? {
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 480, height: 480)
        return try? await generator.image(at: CMTime(seconds: 30, preferredTimescale: 600)).image
    }
}

/// The camera, live.
public struct CameraPreview {
    let camera: TimelapseCamera

    public init(camera: TimelapseCamera) {
        self.camera = camera
    }
}

#if canImport(UIKit)
import UIKit

extension CameraPreview: UIViewRepresentable {
    public final class PreviewView: UIView {
        override public static var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
        var previewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer } // swiftlint:disable:this force_cast
    }

    public func makeUIView(context: Context) -> PreviewView {
        let view = PreviewView()
        camera.attach(view.previewLayer)
        view.previewLayer.videoGravity = .resizeAspectFill
        return view
    }

    public func updateUIView(_ view: PreviewView, context: Context) {}
}
#else
import AppKit

extension CameraPreview: NSViewRepresentable {
    public func makeNSView(context: Context) -> NSView {
        let view = NSView()
        let layer = AVCaptureVideoPreviewLayer()
        camera.attach(layer)
        layer.videoGravity = .resizeAspectFill
        view.wantsLayer = true // layer-backed first, or AppKit replaces the layer it's given
        view.layer = layer
        return view
    }

    public func updateNSView(_ view: NSView, context: Context) {}
}
#endif
