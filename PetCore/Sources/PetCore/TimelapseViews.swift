//
//  TimelapseViews.swift
//  PetCore
//

import AVFoundation
import SwiftUI

/// The timelapses kept on this device: play, share (Save to Photos on iPhone), delete.
public struct TimelapseList: View {
    let library: TimelapseLibrary
    let play: (URL) -> Void

    public init(library: TimelapseLibrary, play: @escaping (URL) -> Void) {
        self.library = library
        self.play = play
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Timelapses").font(.subheadline.bold())
            ForEach(library.videos) { timelapse in
                if let video = timelapse.video {
                    HStack {
                        Button { play(video) } label: {
                            Label(timelapse.startedAt.formatted(date: .abbreviated, time: .shortened), systemImage: "play.circle")
                        }
                        .buttonStyle(.borderless)
                        Text("\(Int((timelapse.recordedSeconds / 60).rounded())) min → 1:00").foregroundStyle(.secondary)
                        Spacer()
                        ShareLink(item: video) { Image(systemName: "square.and.arrow.up") }
                            .buttonStyle(.borderless)
                            .accessibilityLabel("Share")
                        Button(role: .destructive) { library.delete(timelapse) } label: { Image(systemName: "trash") }
                            .buttonStyle(.borderless)
                            .accessibilityLabel("Delete")
                    }
                    .font(.callout)
                }
            }
            Text("\(library.videos.count) of \(TimelapseLibrary.keep) kept · "
                 + ByteCountFormatter.string(fromByteCount: Int64(library.totalBytes), countStyle: .file)
                 + " · only on this device")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}

/// The camera, live.
public struct CameraPreview {
    let session: AVCaptureSession

    public init(session: AVCaptureSession) {
        self.session = session
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
        view.previewLayer.session = session
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
        let layer = AVCaptureVideoPreviewLayer(session: session)
        layer.videoGravity = .resizeAspectFill
        view.wantsLayer = true // layer-backed first, or AppKit replaces the layer it's given
        view.layer = layer
        return view
    }

    public func updateNSView(_ view: NSView, context: Context) {}
}
#endif
