//
//  HomeView.swift
//  befriend
//

import AVKit
import PetCore
import StoreKit
import SwiftUI

/// The friend's personality being written, or why it couldn't be (with Try again). Log out is always there, so a
/// stuck account can be swapped for another.
struct HatchingView: View {
    let model: AppModel
    let name: String
    let failure: String?

    var body: some View {
        VStack(spacing: 20) {
            Spacer()
            CharacterView(skin: model.skins.current, action: .sleep, mood: .sleepy)
            if let failure {
                Text("\(name) is still in the egg").font(.title2.bold())
                Text(failure).multilineTextAlignment(.center).foregroundStyle(.secondary)
                Button("Try again", action: model.retryHatch).buttonStyle(.borderedProminent)
            } else {
                Text("\(name) is hatching…").font(.title2.bold())
                Text("Your friend's personality is being written. This usually takes under a minute; keep the app open.")
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
                ProgressView()
            }
            Spacer()
            Button("Log out") { Task { await model.signOut() } }
                .foregroundStyle(.secondary)
        }
        .padding(32)
    }
}

/// A recorded focus, full screen: the camera, the friend focusing alongside, the countdown. The screen stays on
/// while it records; leaving the app pauses the recording and the gap is skipped.
struct RecordingView: View {
    let model: AppModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        let recorder = model.timelapse.recorder
        let state = model.pomodoro.state
        ZStack {
            Color.black.ignoresSafeArea()
            FramedPreview(camera: recorder.camera, framing: recorder.framing).ignoresSafeArea()
            VStack {
                HStack {
                    Label(recorder.state == .paused ? "Paused" : "REC", systemImage: "record.circle")
                        .font(.headline).foregroundStyle(.red)
                        .padding(8).background(.ultraThinMaterial, in: Capsule())
                    Spacer()
                    if model.posture.isOn { PostureLight(status: model.posture.status) }
                    Spacer()
                    Button { dismiss() } label: { Image(systemName: "chevron.down").font(.title2) }
                        .buttonStyle(.bordered)
                        .accessibilityLabel("Hide; keeps recording")
                }
                Spacer()
                HStack(alignment: .bottom) {
                    CharacterView(skin: model.skins.current, action: .idle, mood: model.pet.mood, focusing: true)
                    Spacer()
                    VStack(alignment: .trailing) {
                        Text("befriend").font(.caption.bold()).opacity(0.85)
                        Text(Pomodoro.clock(state.remaining(at: model.pomodoro.now)))
                            .font(.system(size: 44, weight: .semibold, design: .rounded).monospacedDigit())
                    }
                    .foregroundStyle(.white)
                    .shadow(radius: 4)
                }
                HStack {
                    Button(state.status == .running ? "Pause" : "Resume") {
                        state.status == .running ? model.pomodoro.pause() : model.pomodoro.start()
                    }
                    .buttonStyle(.borderedProminent)
                    Button("Stop") { model.pomodoro.stop() } // saves what was recorded so far
                        .buttonStyle(.bordered)
                        .tint(.white)
                }
                .controlSize(.large)
                .padding(.top)
            }
            .padding()
        }
        .onChange(of: model.timelapse.isRecording) { _, recording in
            if !recording { dismiss() } // the focus ended: the video is in the list
        }
    }
}

private struct PairingCodeItem: Identifiable {
    let id: String
}

struct HomeView: View {
    let model: AppModel
    let friend: FriendProfile

    @State private var showSettings = false
    @State private var showRecording = false
    @State private var showTimelapses = false
    @State private var showFraming = false
    @State private var showChat = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 28) {
                    if model.posture.isOn {
                        PostureLight(status: model.posture.status)
                    }
                    VStack(spacing: 16) {
                        if let dialogue = model.pet.dialogue, !model.pomodoro.state.friendHome {
                            VStack(spacing: 8) {
                                SpeechBubble(text: dialogue)
                                if let followUp = model.pet.followUp {
                                    FollowUpButtons(followUp: followUp, open: model.openChat)
                                }
                            }
                            .transition(.scale(scale: 0.8, anchor: .bottom).combined(with: .opacity))
                        }
                        CharacterView(skin: model.skins.current, action: model.pet.action, mood: model.pet.mood,
                                      focusing: model.pomodoro.state.friendHome)
                            .contentShape(Rectangle())
                            .onTapGesture { Task { await model.poke() } }
                            .accessibilityAddTraits(.isButton)
                            .accessibilityLabel("Poke \(friend.name)")
                    }
                    // Room for the friend and a two-line bubble; a longer one grows it.
                    .frame(maxWidth: .infinity, minHeight: 140, alignment: .bottom)
                    .animation(.snappy, value: model.pet.dialogue)

                    VStack(spacing: 8) {
                        Text(friend.name).font(.largeTitle.bold())
                        if let content = friend.personality.content {
                            Text(content.summary)
                                .multilineTextAlignment(.center)
                                .foregroundStyle(.secondary)
                            Text(content.traits.joined(separator: " · "))
                                .font(.subheadline.weight(.medium))
                        }
                    }

                    PomodoroControls(pomodoro: model.pomodoro, timelapse: model.timelapse,
                                     openRecording: { showRecording = true },
                                     openTimelapses: { showTimelapses = true },
                                     openFraming: { showFraming = true })
                        .padding()
                        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 16))

                    PostureControls(checker: model.posture)
                        .padding()
                        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 16))

                    chart

                    VStack(alignment: .leading, spacing: 8) {
                        Label("Bring \(friend.name) to your Mac", systemImage: "laptopcomputer")
                            .font(.headline)
                        Text("Open befriend on your Mac and scan the QR code it shows with your iPhone's Camera.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding()
                    .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 16))
                }
                .padding()
            }
            .toolbar {
                Button {
                    showChat = true
                } label: {
                    Image(systemName: "bubble.left.and.text.bubble.right")
                }
                .accessibilityLabel("Chat about your files")
                Button {
                    showSettings = true
                } label: {
                    Image(systemName: "gearshape")
                }
                .accessibilityLabel("Settings")
            }
            .sheet(isPresented: $showSettings) {
                SettingsView(model: model)
            }
            .sheet(isPresented: $showFraming) {
                TimelapseFramingView(pomodoro: model.pomodoro, camera: model.timelapse.recorder.camera,
                                     recording: model.timelapse.isRecording)
            }
            .navigationDestination(isPresented: $showTimelapses) {
                TimelapseGallery(library: model.timelapse.library).navigationTitle("Timelapses")
            }
            .fullScreenCover(isPresented: $showChat) {
                ChatRoot(library: model.chat, friend: friend, navigator: model.chatNavigator, sync: model.chatSync) { showChat = false }
            }
            .onChange(of: model.chatNavigator.pending) { _, start in
                if start != nil { showChat = true }
            }
            .alert("Sync chats with this Mac?", isPresented: Binding(
                get: { model.pendingChatInvitation != nil },
                set: { if !$0 { model.pendingChatInvitation = nil } }
            ), presenting: model.pendingChatInvitation) { invitation in
                Button("Sync") { model.acceptChatInvitation(invitation) }
                Button("Cancel", role: .cancel) {}
            } message: { _ in
                Text("Only continue if you just scanned the code on your own Mac. Your chats' key goes to it encrypted, and your chats sync between them.")
            }
            .confirmationDialog("Follow up on this chat?", isPresented: Binding(
                get: { model.pendingFollowUp != nil },
                set: { if !$0 { model.pendingFollowUp = nil } }
            ), presenting: model.pendingFollowUp) { followUp in
                Button("New chat") { model.openChat(ChatStart(conversation: nil, draft: followUp.question)) }
                Button("Continue that chat") { model.openChat(ChatStart(conversation: followUp.conversationID, draft: followUp.question)) }
            } message: { followUp in
                Text(followUp.question)
            }
            .fullScreenCover(isPresented: $showRecording) {
                RecordingView(model: model)
            }
            .onChange(of: model.timelapse.isRecording) { _, recording in
                // A recorded focus opens the recording view; closing it keeps recording, and the focus card's
                // "Recording — Open camera" brings it back.
                showRecording = recording
            }
            .sheet(item: Binding(
                get: { model.pendingPairingCode.map(PairingCodeItem.init) },
                set: { model.pendingPairingCode = $0?.id }
            )) { item in
                PairingConfirmView(model: model, code: item.id)
            }
        }
    }

    private var chart: some View {
        let chart = friend.chart
        return LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
            chip("Star sign", chart.westernSign.capitalized, "sparkles")
            chip("Chinese zodiac", "\(chart.chineseElement.capitalized) \(chart.chineseAnimal.capitalized)", "moon.stars")
            chip("Energy", chart.chinesePolarity.capitalized, "circle.lefthalf.filled")
            chip("Nine Star Ki", "\(chart.fengShuiStar) \(chart.fengShuiElement.capitalized)", "leaf")
        }
    }

    private func chip(_ title: String, _ value: String, _ symbol: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Label(title, systemImage: symbol).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.subheadline.weight(.semibold))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 12))
    }
}

/// "Pair <Mac>?" after scanning the Mac's QR code.
struct PairingConfirmView: View {
    let model: AppModel
    let code: String

    private enum LoadState {
        case loading
        case ready(PairingInfo)
        case confirming(PairingInfo)
        case expired
        case paired(String)
        case failed(String)
    }

    @Environment(\.dismiss) private var dismiss
    @State private var state = LoadState.loading

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "laptopcomputer.and.iphone")
                .font(.system(size: 52))
                .foregroundStyle(.tint)
            switch state {
            case .loading:
                ProgressView()
            case .ready(let info), .confirming(let info):
                Text("Pair “\(info.deviceName)”?").font(.title2.bold()).multilineTextAlignment(.center)
                Text("Only pair a Mac you're setting up right now. Check that it shows the code **\(Self.displayCode(code))**.")
                    .multilineTextAlignment(.center)
                Text("That Mac gets access to your account, your friend and your chats, and syncs its activity to you.")
                    .font(.footnote)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
                Button("Pair") { Task { await confirm(info) } }
                    .buttonStyle(.borderedProminent)
                    .disabled(isConfirming)
                Button("Not now", role: .cancel) { dismiss() }
            case .expired:
                Text("This code has expired").font(.title3.bold())
                Text("Your Mac shows a new code every two minutes. Scan the new one.")
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
                Button("OK") { dismiss() }
            case .paired(let deviceName):
                Text("Paired with “\(deviceName)”").font(.title3.bold()).multilineTextAlignment(.center)
                Text("Your friend appears on your Mac in a moment.").foregroundStyle(.secondary)
                Button("Done") { dismiss() }.buttonStyle(.borderedProminent)
            case .failed(let message):
                Text(message).multilineTextAlignment(.center)
                Button("Close") { dismiss() }
            }
        }
        .controlSize(.large)
        .padding(32)
        .presentationDetents([.medium])
        .task { await load() }
    }

    /// The code as the Mac shows it: uppercase, no separators.
    static func displayCode(_ code: String) -> String {
        code.uppercased().filter { $0.isLetter || $0.isNumber }
    }

    private var isConfirming: Bool {
        if case .confirming = state { true } else { false }
    }

    private func load() async {
        do {
            state = try await model.api.pairingInfo(code: code).map(LoadState.ready) ?? .expired
        } catch {
            state = .failed(AppModel.message(for: error))
        }
    }

    private func confirm(_ info: PairingInfo) async {
        state = .confirming(info)
        do {
            try await model.api.confirmPairing(code: code)
            state = .paired(info.deviceName)
            if let invitation = model.pairingChatInvitation { // confirmed with the pairing itself
                model.pairingChatInvitation = nil
                model.acceptChatInvitation(invitation)
            }
        } catch APIError.server(status: 404, _, _) {
            state = .expired
        } catch {
            state = .failed(AppModel.message(for: error))
        }
    }
}

struct SettingsView: View {
    let model: AppModel

    @Environment(\.dismiss) private var dismiss
    @State private var sync: SyncSettings?
    @State private var confirmDeleteAccount = false
    @State private var confirmDeleteActivity = false
    @State private var busy = false
    @State private var error: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    skinRow("Pixel Cat", id: nil)
                    ForEach(model.skins.granted) { skin in
                        skinRow(skin.name, id: skin.id)
                    }
                } header: {
                    Text("Look")
                } footer: {
                    Text("Your friend looks the same on your iPhone and Mac. Skins you're given show up here. A new look takes a minute: your friend learns what it can do in it first.")
                }

                if !model.shop.items.isEmpty {
                    Section {
                        ForEach(model.shop.items) { item in
                            shopRow(item)
                        }
                        Button("Restore purchases") { Task { await model.shop.restore() } }
                            .disabled(model.shop.busy != nil)
                        if let message = model.shop.message {
                            Text(message).font(.footnote).foregroundStyle(.secondary)
                        }
                    } header: {
                        Text("Shop")
                    } footer: {
                        Text("A bought skin is yours on every device you sign in to befriend with.")
                    }
                }

                Section {
                    if let sync {
                        Toggle("Pause activity sync", isOn: Binding(
                            get: { sync.logSyncPaused },
                            set: { paused in Task { await updateSync { try await model.api.updateSyncSettings(paused: paused) } } }
                        ))
                        if sync.excludedApps.isEmpty {
                            Text("No apps excluded. On your Mac, choose Stop Tracking in befriend's menu.")
                                .foregroundStyle(.secondary)
                        } else {
                            ForEach(sync.excludedApps, id: \.self) { app in
                                Label(app, systemImage: "eye.slash")
                            }
                            .onDelete { offsets in
                                var apps = sync.excludedApps
                                apps.remove(atOffsets: offsets)
                                Task { await updateSync { try await model.api.updateSyncSettings(excludedApps: apps) } }
                            }
                        }
                        Button("Delete synced activity", role: .destructive) { confirmDeleteActivity = true }
                    } else {
                        ProgressView()
                    }
                } header: {
                    Text("Activity")
                } footer: {
                    Text("Your Mac syncs the apps you switch between and when you're away, so your friend can grow each week. Excluded apps are never synced.")
                }

                Section {
                    Button("Sign out") {
                        Task {
                            busy = true
                            await model.signOut()
                            dismiss()
                        }
                    }
                }
                Section {
                    Button("Delete account", role: .destructive) { confirmDeleteAccount = true }
                } footer: {
                    Text("Deletes your account, your friend and all synced activity. This can't be undone.")
                }
                if let error {
                    Text(error).foregroundStyle(.red)
                }
            }
            .disabled(busy)
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .task {
                do {
                    sync = try await model.api.syncSettings()
                } catch {
                    self.error = AppModel.message(for: error)
                }
            }
            .task { await model.skins.sync(api: model.api) }
            .task { await model.shop.load() }
            .confirmationDialog("Delete your synced activity?", isPresented: $confirmDeleteActivity, titleVisibility: .visible) {
                Button("Delete activity", role: .destructive) {
                    Task { await perform { try await model.api.deleteTriggerEvents() } }
                }
            } message: {
                Text("Your friend stays; the app switches and away times synced so far are deleted.")
            }
            .confirmationDialog("Delete your account?", isPresented: $confirmDeleteAccount, titleVisibility: .visible) {
                Button("Delete account", role: .destructive) {
                    Task {
                        await perform { try await model.deleteAccount() }
                        if error == nil { dismiss() }
                    }
                }
            } message: {
                Text("Your friend will be gone for good.")
            }
        }
    }

    private func shopRow(_ item: SkinShop.Item) -> some View {
        HStack(spacing: 12) {
            if let preview = item.skin.preview {
                PixelImage(data: preview).frame(width: 32, height: 32)
            }
            Text(item.skin.name)
            Spacer()
            if item.skin.owned {
                Text("Owned").foregroundStyle(.secondary)
            } else if model.shop.busy == item.id {
                ProgressView()
            } else if let product = item.product {
                Button(product.displayPrice) { Task { await model.shop.buy(item) } }
                    .buttonStyle(.bordered)
                    .disabled(model.shop.busy != nil)
                    .accessibilityLabel("Buy \(item.skin.name) for \(product.displayPrice)")
            } else {
                Text("Coming soon").foregroundStyle(.secondary)
            }
        }
    }

    /// A skin choice; picking one saves it for the whole account and downloads it if needed.
    private func skinRow(_ name: String, id: String?) -> some View {
        Button {
            Task { await perform { try await model.skins.select(id, api: model.api) } }
        } label: {
            HStack {
                Text(name).foregroundStyle(.primary)
                Spacer()
                if model.skins.pending.map({ $0.skinId == id }) ?? false {
                    ProgressView()
                    Text("Teaching \(model.friend?.name ?? "your friend") new moves…").font(.footnote).foregroundStyle(.secondary)
                } else if model.skins.current?.pickID == id {
                    Image(systemName: "checkmark").foregroundStyle(.tint)
                }
            }
        }
    }

    private func updateSync(_ change: () async throws -> SyncSettings) async {
        await perform {
            let updated = try await change()
            sync = updated
            model.syncSettingsChanged(updated)
        }
    }

    private func perform(_ action: () async throws -> Void) async {
        busy = true
        error = nil
        defer { busy = false }
        do {
            try await action()
        } catch {
            self.error = AppModel.message(for: error)
        }
    }
}
