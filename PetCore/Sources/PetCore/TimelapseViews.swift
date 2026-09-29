//
//  TimelapseViews.swift
//  PetCore
//

import AVFoundation
import AVKit
import SwiftUI

/// The timelapses kept on this device as a grid (M13): the iPhone's Timelapses page and the Mac's window. Tap plays
/// full size; the context menu (VoiceOver: actions) shares, shows in Finder on the Mac, or deletes after asking.
public struct TimelapseGallery: View {
    let library: TimelapseLibrary
    /// The Mac's "Show in Finder"; nil on iPhone.
    let reveal: ((URL) -> Void)?
    @State private var playing: PlayingVideo?
    @State private var deleting: Timelapse?

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
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 16)], spacing: 20) {
                        ForEach(library.videos) { timelapse in
                            if let video = timelapse.video { tile(timelapse, video) }
                        }
                    }
                    .padding()
                    Text("\(library.videos.count) of \(TimelapseLibrary.keep) kept · "
                         + ByteCountFormatter.string(fromByteCount: Int64(library.totalBytes), countStyle: .file)
                         + " · only on this device. The oldest is removed when a new one is saved.")
                        .font(.footnote).foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding([.horizontal, .bottom])
                }
            }
        }
        .sheet(item: $playing) { video in
            VideoPlayer(player: video.player)
                .frame(minWidth: 480, minHeight: 360)
                .ignoresSafeArea()
                .onAppear { video.player.play() }
        }
        .confirmationDialog("Delete this timelapse?", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
                            titleVisibility: .visible, presenting: deleting) { timelapse in
            Button("Delete", role: .destructive) { library.delete(timelapse) }
        } message: { _ in
            Text("It's only on this device, so it can't be recovered.")
        }
    }

    private func tile(_ timelapse: Timelapse, _ video: URL) -> some View {
        Button { playing = PlayingVideo(player: AVPlayer(url: video), id: video) } label: {
            VStack(alignment: .leading, spacing: 6) {
                Thumbnail(url: video)
                    .aspectRatio(3 / 4, contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .overlay {
                        Image(systemName: "play.circle.fill")
                            .font(.largeTitle)
                            .symbolRenderingMode(.palette)
                            .foregroundStyle(.white, .black.opacity(0.45))
                    }
                Text(timelapse.startedAt.formatted(.relative(presentation: .named, unitsStyle: .wide)).capitalized)
                    .font(.subheadline.weight(.semibold))
                Text("\(Self.minutes(timelapse)) min focus → 1:00")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu { menu(timelapse, video) }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Focus on \(timelapse.startedAt.formatted(date: .long, time: .shortened)), \(Self.minutes(timelapse)) minutes, a 1-minute video")
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

    private static func minutes(_ timelapse: Timelapse) -> Int {
        max(1, Int((timelapse.recordedSeconds / 60).rounded()))
    }
}

private struct PlayingVideo: Identifiable {
    let player: AVPlayer
    let id: URL
}

/// A still from the middle of the video.
private struct Thumbnail: View {
    let url: URL
    @State private var image: CGImage?

    var body: some View {
        ZStack {
            Rectangle().fill(.quaternary)
            if let image {
                Image(decorative: image, scale: 1).resizable().scaledToFill()
            }
        }
        .task(id: url) { image = await Self.still(url) }
    }

    // ponytail: regenerated each time a tile appears; the library keeps 10, so no cache.
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
