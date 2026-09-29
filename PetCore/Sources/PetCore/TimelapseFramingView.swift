//
//  TimelapseFramingView.swift
//  PetCore
//

import SwiftUI

/// The live camera with everything outside the kept box dimmed: the framing screen, and the recording previews
/// (iPhone full screen, Mac popover), so what's kept is visible while recording.
public struct FramedPreview: View {
    let camera: TimelapseCamera
    let framing: TimelapseFraming
    @State private var frameSize: CGSize?

    public init(camera: TimelapseCamera, framing: TimelapseFraming) {
        self.camera = camera
        self.framing = framing
    }

    public var body: some View {
        CameraPreview(camera: camera)
            .overlay {
                if let frameSize, framing.format != .original {
                    GeometryReader { geo in
                        CropMask(box: Self.box(framing.box(in: frameSize), frame: frameSize, in: geo.size))
                    }
                }
            }
            .task { await FrameSize.follow(camera) { frameSize = $0 } }
    }

    /// Where a box (shares of the frame) lands in a view that shows the frame aspect-filled, like the preview.
    static func box(_ box: CGRect, frame: CGSize, in view: CGSize) -> CGRect {
        let scale = max(view.width / frame.width, view.height / frame.height)
        let shown = CGSize(width: frame.width * scale, height: frame.height * scale)
        let origin = CGPoint(x: (view.width - shown.width) / 2, y: (view.height - shown.height) / 2)
        return CGRect(x: origin.x + box.minX * shown.width, y: origin.y + box.minY * shown.height,
                      width: box.width * shown.width, height: box.height * shown.height)
    }
}

/// Dims all but `box`, with a thin outline around it.
struct CropMask: View {
    let box: CGRect

    var body: some View {
        ZStack {
            Path { path in
                path.addRect(CGRect(x: -10_000, y: -10_000, width: 20_000, height: 20_000))
                path.addRect(box)
            }
            .fill(.black.opacity(0.55), style: FillStyle(eoFill: true))
            Rectangle().strokeBorder(.white, lineWidth: 2).frame(width: box.width, height: box.height)
                .position(x: box.midX, y: box.midY)
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// The camera's frame size, as it changes (the iPhone turns).
enum FrameSize {
    @MainActor static func follow(_ camera: TimelapseCamera, _ update: (CGSize) -> Void) async {
        while !Task.isCancelled {
            if let size = camera.latest?.extent.size { update(size) }
            try? await Task.sleep(for: .milliseconds(500))
        }
    }
}

/// Exactly what will be recorded, live: the kept part of the camera at the video's shape, with the watermark and
/// clock where the video draws them.
struct LiveCropPreview: View {
    let camera: TimelapseCamera
    let framing: TimelapseFraming
    let focus: TimeInterval
    @State private var image: CGImage?
    @State private var shape = CGSize(width: 9, height: 16)

    private static let context = CIContext()
    private static let maxSide: CGFloat = 480
    private static let refresh: Duration = .milliseconds(100)

    var body: some View {
        Rectangle()
            .fill(.black)
            .overlay {
                if let image { Image(decorative: image, scale: 1).resizable().scaledToFill() }
            }
            .overlay {
                GeometryReader { geo in
                    TimelapseOverlay(size: geo.size, friend: nil, clock: "00:00 / " + Pomodoro.clock(focus))
                }
            }
            .clipped()
            .aspectRatio(shape.width / shape.height, contentMode: .fit)
            .frame(maxHeight: 360)
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .accessibilityElement()
            .accessibilityLabel("Live preview of what's recorded, \(framing.format.title)")
            .task(id: framing) {
                while !Task.isCancelled {
                    if let full = camera.latest {
                        let crop = framing.crop(in: full.extent)
                        shape = crop.size
                        image = await Self.render(full.cropped(to: crop))
                    }
                    try? await Task.sleep(for: Self.refresh)
                }
            }
    }

    /// Scaled down off the main thread: a preview doesn't need 4K.
    private static func render(_ image: CIImage) async -> CGImage? {
        await Task.detached(priority: .userInitiated) {
            let scale = min(1, maxSide / max(image.extent.width, image.extent.height))
            let small = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
            return context.createCGImage(small, from: small.extent)
        }.value
    }
}

/// "Video format": pick a shape, drag the box onto yourself, pick a zoom preset. Done saves it for the next
/// recording; while one runs, it keeps its framing and this applies from the next focus.
public struct TimelapseFramingView: View {
    let pomodoro: PomodoroRunner
    let camera: TimelapseCamera
    let recording: Bool
    let finish: (() -> Void)?
    @Environment(\.dismiss) private var dismiss
    @State private var framing: TimelapseFraming
    @State private var frameSize: CGSize?
    @State private var dragFrom: CGPoint?

    private static let cameraUser = "framing"
    private static let step: CGFloat = 0.05

    public init(pomodoro: PomodoroRunner, camera: TimelapseCamera, recording: Bool, finish: (() -> Void)? = nil) {
        self.pomodoro = pomodoro
        self.camera = camera
        self.recording = recording
        self.finish = finish
        _framing = State(initialValue: pomodoro.state.settings.framing)
    }

    public var body: some View {
        VStack(spacing: 14) {
            Text("Video format").font(.title2.bold())
            Picker("Format", selection: $framing.format) {
                ForEach(TimelapseFormat.allCases) { Text($0.shortTitle).tag($0) }
            }
            .pickerStyle(.segmented)
            Text("\(framing.format.title) · \(framing.format.platforms)")
                .font(.callout).foregroundStyle(.secondary)
            HStack(alignment: .top, spacing: 12) {
                VStack(spacing: 6) {
                    preview
                    Text("Camera").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                }
                VStack(spacing: 6) {
                    LiveCropPreview(camera: camera, framing: framing, focus: pomodoro.state.settings.focus)
                    Label("Recorded", systemImage: "record.circle").font(.caption.weight(.semibold)).foregroundStyle(.red)
                }
            }
            if framing.format != .original {
                Picker("Zoom", selection: $framing.placement.zoom) {
                    ForEach(TimelapseZoom.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                Text("Drag the box to where you sit. Only what's inside it is recorded.")
                    .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
            }
            if recording {
                Label("This focus keeps its framing; changes apply from your next one.", systemImage: "info.circle")
                    .font(.caption).foregroundStyle(.secondary)
            }
            HStack {
                Button("Reset") { framing.placement = TimelapsePlacement() }
                    .disabled(framing.format == .original)
                Spacer()
                Button("Cancel", role: .cancel) { close() }.keyboardShortcut(.cancelAction)
                Button("Done") {
                    pomodoro.update(pomodoro.state.settings.with(framing: framing))
                    close()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
            }
            .controlSize(.large)
        }
        .padding(24)
        #if os(macOS)
        .frame(minWidth: 520) // camera and result side by side
        #endif
        .onAppear { camera.start(for: Self.cameraUser) }
        .onDisappear { camera.stop(for: Self.cameraUser) }
        .task { await FrameSize.follow(camera) { frameSize = $0 } }
    }

    /// The whole camera frame (not cropped by the view), so the box maps one to one.
    private var preview: some View {
        let size = frameSize ?? CGSize(width: 16, height: 9)
        return CameraPreview(camera: camera)
            .aspectRatio(size.width / size.height, contentMode: .fit)
            .frame(maxHeight: 360)
            .overlay {
                if framing.format != .original {
                    GeometryReader { geo in
                        let box = FramedPreview.box(framing.box(in: size), frame: size, in: geo.size)
                        ZStack {
                            CropMask(box: box)
                            Color.clear
                                .contentShape(Rectangle())
                                .frame(width: box.width, height: box.height)
                                .position(x: box.midX, y: box.midY)
                                .gesture(drag(in: geo.size, frame: size))
                                .accessibilityElement()
                                .accessibilityLabel("Kept area")
                                .accessibilityHint("Use the actions to move it")
                                .accessibilityAction(named: "Move left") { nudge(-Self.step, 0, size) }
                                .accessibilityAction(named: "Move right") { nudge(Self.step, 0, size) }
                                .accessibilityAction(named: "Move up") { nudge(0, -Self.step, size) }
                                .accessibilityAction(named: "Move down") { nudge(0, Self.step, size) }
                        }
                    }
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    private func drag(in view: CGSize, frame: CGSize) -> some Gesture {
        DragGesture()
            .onChanged { value in
                let from = dragFrom ?? framing.placement.center
                dragFrom = from
                let center = CGPoint(x: from.x + value.translation.width / view.width,
                                     y: from.y + value.translation.height / view.height)
                framing = framing.moved(to: center, frameSize: frame)
            }
            .onEnded { _ in dragFrom = nil }
    }

    private func nudge(_ dx: CGFloat, _ dy: CGFloat, _ frame: CGSize) {
        let center = framing.placement.center
        framing = framing.moved(to: CGPoint(x: center.x + dx, y: center.y + dy), frameSize: frame)
    }

    private func close() {
        if let finish { finish() } else { dismiss() }
    }
}
