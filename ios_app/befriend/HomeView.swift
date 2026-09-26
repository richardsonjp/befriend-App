//
//  HomeView.swift
//  befriend
//

import PetCore
import SwiftUI

struct HatchingView: View {
    let name: String

    var body: some View {
        VStack(spacing: 20) {
            CharacterView(skin: SkinInstaller.current(in: SharedStore.skinsRoot), action: .sleep, mood: .sleepy)
            Text("\(name) is hatching…").font(.title2.bold())
            Text("Your friend's personality is being written. This can take a minute.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
            ProgressView()
        }
        .padding(32)
    }
}

private struct PairingCodeItem: Identifiable {
    let id: String
}

struct HomeView: View {
    let model: AppModel
    let friend: FriendProfile

    @State private var showSettings = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 28) {
                    VStack(spacing: 16) {
                        if let dialogue = model.pet.dialogue, !model.pomodoro.state.friendHome {
                            SpeechBubble(text: dialogue)
                                .transition(.scale(scale: 0.8, anchor: .bottom).combined(with: .opacity))
                        }
                        CharacterView(skin: model.skins.current, action: model.pet.action, mood: model.pet.mood,
                                      focusing: model.pomodoro.state.friendHome)
                            .contentShape(Rectangle())
                            .onTapGesture { Task { await model.poke() } }
                            .accessibilityAddTraits(.isButton)
                            .accessibilityLabel("Poke \(friend.name)")
                    }
                    .frame(maxWidth: .infinity, minHeight: 220, alignment: .bottom)
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

                    PomodoroControls(pomodoro: model.pomodoro)
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
                    showSettings = true
                } label: {
                    Image(systemName: "gearshape")
                }
                .accessibilityLabel("Settings")
            }
            .sheet(isPresented: $showSettings) {
                SettingsView(model: model)
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
                Text("That Mac gets access to your account and your friend, and syncs its activity to you.")
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
                    Text("Getting dressed…").font(.footnote).foregroundStyle(.secondary)
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
