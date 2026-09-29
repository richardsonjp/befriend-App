//
//  PostureViews.swift
//  PetCore
//

import SwiftUI

public extension PostureChecker.Status {
    /// Always said in words beside the colour, never by colour alone.
    var title: String {
        switch self {
        case .off: "Posture check off"
        case .paused: "Paused"
        case .nobody: "Can't see you"
        case .good: "Good posture"
        case .slouching: "Sit up straight"
        }
    }

    var color: Color {
        switch self {
        case .good: .green
        case .slouching: .red
        case .off, .paused, .nobody: .gray
        }
    }
}

/// The posture light: a coloured dot and what it means, in a capsule.
public struct PostureLight: View {
    let status: PostureChecker.Status

    public init(status: PostureChecker.Status) {
        self.status = status
    }

    public var body: some View {
        HStack(spacing: 6) {
            Circle().fill(status.color.gradient).frame(width: 10, height: 10)
            Text(status.title).font(.subheadline.weight(.medium))
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(.thinMaterial, in: Capsule())
        .animation(.snappy, value: status)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Posture: \(status.title)")
    }
}

/// The posture card: the switch, the light, and re-calibration. The first switch-on calibrates first.
/// `presentCalibration` shows the calibration elsewhere (the Mac opens a window: a popover can't host a sheet);
/// without it, a sheet opens here. Its argument says whether to turn the checker on once calibrated.
public struct PostureControls: View {
    let checker: PostureChecker
    let presentCalibration: ((_ turnOnAfter: Bool) -> Void)?
    @State private var sheetTurnsOn: Bool?
    @State private var cameraDenied = false

    public init(checker: PostureChecker, presentCalibration: ((Bool) -> Void)? = nil) {
        self.checker = checker
        self.presentCalibration = presentCalibration
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("Posture", systemImage: "figure.stand").font(.headline)
                Spacer()
                if checker.isOn { PostureLight(status: checker.status) }
            }
            Toggle("Check my posture", isOn: Binding(get: { checker.isOn }, set: switchChanged))
            if cameraDenied {
                Text("befriend can't use the camera. Allow it in System Settings › Privacy & Security › Camera.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if checker.isOn, checker.needsRecalibration {
                Label("Moved your camera or chair? Re-calibrate so the light stays right.", systemImage: "exclamationmark.triangle.fill")
                    .font(.caption).foregroundStyle(.orange)
            }
            if checker.baseline != nil {
                Button("Re-calibrate…") { calibrate(turnOnAfter: false) }
            }
            Text("Watches with this device's camera while on. Nothing is recorded or leaves the device.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .sheet(isPresented: Binding(get: { sheetTurnsOn != nil }, set: { if !$0 { sheetTurnsOn = nil } })) {
            PostureCalibrationView(checker: checker, turnOnAfter: sheetTurnsOn ?? false)
        }
    }

    private func switchChanged(_ on: Bool) {
        guard on else { return checker.setOn(false) }
        Task {
            cameraDenied = !(await TimelapseCamera.requestAccess())
            guard !cameraDenied else { return }
            if checker.baseline == nil { calibrate(turnOnAfter: true) } else { checker.setOn(true) }
        }
    }

    private func calibrate(turnOnAfter: Bool) {
        if let presentCalibration { presentCalibration(turnOnAfter) } else { sheetTurnsOn = turnOnAfter }
    }
}

/// "Sit the way you want to sit": a live camera and Calibrate. Cancel keeps the old calibration; a failed one
/// (head and shoulders not in view) keeps it too and says why.
public struct PostureCalibrationView: View {
    let checker: PostureChecker
    let turnOnAfter: Bool
    let finish: (() -> Void)?
    @Environment(\.dismiss) private var dismiss
    @State private var working = false
    @State private var failed = false

    public init(checker: PostureChecker, turnOnAfter: Bool, finish: (() -> Void)? = nil) {
        self.checker = checker
        self.turnOnAfter = turnOnAfter
        self.finish = finish
    }

    public var body: some View {
        VStack(spacing: 16) {
            Text("Sit the way you want to sit").font(.title2.bold())
            Text("Sit up straight with your shoulders relaxed, facing the screen, so your head and shoulders are in view. befriend remembers this as your good posture.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
            CameraPreview(camera: checker.camera)
                .aspectRatio(4 / 3, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 16))
                .accessibilityLabel("Camera preview")
            if failed {
                Label("Couldn't see your head and shoulders. Move so they're in the frame, then try again.",
                      systemImage: "exclamationmark.circle.fill")
                    .font(.callout).foregroundStyle(.orange)
            }
            HStack {
                Button("Cancel", role: .cancel) { close() }
                    .keyboardShortcut(.cancelAction)
                Button(working ? "Hold still…" : "Calibrate", action: calibrate)
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(working)
            }
            .controlSize(.large)
        }
        .padding(24)
        .frame(minWidth: 360)
        .onAppear { checker.preview(true) }
        .onDisappear { checker.preview(false) }
    }

    private func calibrate() {
        Task {
            working = true
            failed = false
            let saved = await checker.calibrate()
            working = false
            guard saved else { return failed = true }
            if turnOnAfter { checker.setOn(true) }
            close()
        }
    }

    private func close() {
        if let finish { finish() } else { dismiss() }
    }
}
