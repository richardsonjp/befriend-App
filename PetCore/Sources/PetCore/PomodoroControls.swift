//
//  PomodoroControls.swift
//  PetCore
//

import SwiftUI

/// The focus timer's card: the Mac's menu bar popover and the iPhone's Home screen. One step: set the minutes,
/// start, pause or stop. With `timelapse`, a focus can be recorded (M11); `preview` shows the camera inline while
/// recording (Mac), `openRecording` offers a way back to a full-screen recording view (iPhone), and
/// `openTimelapses` opens the page of saved videos. `more`, when given, adds a "…" button (the Mac's menu).
public struct PomodoroControls: View {
    let pomodoro: PomodoroRunner
    let timelapse: TimelapseController?
    let preview: Bool
    let openRecording: (() -> Void)?
    let openTimelapses: (() -> Void)?
    let openFraming: (() -> Void)?
    let more: (() -> Void)?
    @State private var cameraDenied = false

    public init(pomodoro: PomodoroRunner, timelapse: TimelapseController? = nil, preview: Bool = false,
                openRecording: (() -> Void)? = nil, openTimelapses: (() -> Void)? = nil, openFraming: (() -> Void)? = nil,
                more: (() -> Void)? = nil) {
        self.pomodoro = pomodoro
        self.timelapse = timelapse
        self.preview = preview
        self.openRecording = openRecording
        self.openTimelapses = openTimelapses
        self.openFraming = openFraming
        self.more = more
    }

    public var body: some View {
        let state = pomodoro.state
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("🍅 Focus").font(.headline)
                Spacer()
                Text("Today: \(state.completedToday(at: pomodoro.now))").foregroundStyle(.secondary)
                    .accessibilityLabel("\(state.completedToday(at: pomodoro.now)) focus sessions finished today")
                if let more {
                    Button { more() } label: { Image(systemName: "ellipsis.circle") }
                        .buttonStyle(.borderless)
                        .accessibilityLabel("More")
                }
            }
            Text(Pomodoro.clock(state.remaining(at: pomodoro.now)))
                .font(.system(size: 44, weight: .semibold, design: .rounded).monospacedDigit())
                .accessibilityLabel(spokenTime(state.remaining(at: pomodoro.now)) + (state.status == .ready ? "" : " left"))
            if state.status == .ready {
                Stepper("\(Int(state.settings.focus / 60)) min", value: minutes, in: 1...180)
            }
            HStack {
                primaryButton(state).buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                if state.status != .ready {
                    Button("Stop") { pomodoro.stop() }.buttonStyle(.bordered)
                }
            }
            if let timelapse, timelapse.isRecording, let openRecording {
                Button(action: openRecording) {
                    Label(timelapse.recorder.state == .paused ? "Recording paused — Open camera" : "Recording — Open camera",
                          systemImage: "record.circle")
                }
                .buttonStyle(.bordered)
                .tint(.red)
            }
            Toggle("Friend stays home during focus", isOn: setting(\.friendStaysHome) { $0.with(friendStaysHome: $1) })
            if state.friendHome {
                Button("Let friend out") { pomodoro.letFriendOut() }
            }
            Toggle("Sound when focus ends", isOn: setting(\.sound) { $0.with(sound: $1) })
            if let timelapse {
                timelapseSection(timelapse, state)
            }
        }
    }

    @ViewBuilder
    private func timelapseSection(_ timelapse: TimelapseController, _ state: Pomodoro) -> some View {
        Toggle("Record a timelapse of each focus", isOn: Binding(
            get: { state.settings.recordTimelapse },
            set: { on in
                guard on else { return pomodoro.update(state.settings.with(recordTimelapse: false)) }
                Task {
                    cameraDenied = !(await TimelapseCamera.requestAccess())
                    if !cameraDenied { pomodoro.update(pomodoro.state.settings.with(recordTimelapse: true)) }
                }
            }
        ))
        if cameraDenied || (state.settings.recordTimelapse && !TimelapseCamera.permitted) {
            Text("befriend can't use the camera. Allow it in System Settings › Privacy & Security › Camera.")
                .font(.caption).foregroundStyle(.secondary)
        }
        if state.settings.recordTimelapse, let openFraming {
            Button(action: openFraming) {
                HStack {
                    Label("Video format", systemImage: "crop")
                    Spacer()
                    Text(state.settings.framing.format.title).foregroundStyle(.secondary)
                    Image(systemName: "chevron.right").foregroundStyle(.tertiary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Video format, \(state.settings.framing.format.title)")
        }
        if preview, timelapse.isRecording {
            FramedPreview(camera: timelapse.recorder.camera, framing: timelapse.recorder.framing)
                .aspectRatio(16 / 9, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(alignment: .topLeading) {
                    Label(timelapse.recorder.state == .paused ? "Paused" : "REC", systemImage: "record.circle")
                        .font(.caption.bold()).foregroundStyle(.red).padding(6)
                }
                .accessibilityLabel(timelapse.recorder.state == .paused ? "Camera preview, recording paused" : "Camera preview, recording")
        }
        if let openTimelapses {
            Button(action: openTimelapses) {
                HStack {
                    Label("Timelapses", systemImage: "film.stack")
                    Spacer()
                    Text("\(timelapse.library.videos.count)").foregroundStyle(.secondary)
                    Image(systemName: "chevron.right").foregroundStyle(.tertiary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Timelapses, \(timelapse.library.videos.count) saved")
        }
    }

    @ViewBuilder
    private func primaryButton(_ state: Pomodoro) -> some View {
        switch state.status {
        case .ready: Button("Start focus") { pomodoro.start() }
        case .running: Button("Pause") { pomodoro.pause() }
        case .paused: Button("Resume") { pomodoro.start() }
        }
    }

    private func spokenTime(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded(.up))
        return Duration.seconds(total).formatted(.units(allowed: [.minutes, .seconds], width: .wide))
    }

    private var minutes: Binding<Int> {
        Binding(get: { Int(pomodoro.state.settings.focus / 60) },
                set: { pomodoro.update(pomodoro.state.settings.with(focus: TimeInterval($0 * 60))) })
    }

    private func setting<Value>(_ read: KeyPath<PomodoroSettings, Value>,
                                _ write: @escaping (PomodoroSettings, Value) -> PomodoroSettings) -> Binding<Value> {
        Binding(get: { pomodoro.state.settings[keyPath: read] },
                set: { pomodoro.update(write(pomodoro.state.settings, $0)) })
    }
}
