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
            PlaceholderCharacterView(action: .sleep, mood: .sleepy)
            Text("\(name) is hatching…").font(.title2.bold())
            Text("Your friend's personality is being written. This can take a minute.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
            ProgressView()
        }
        .padding(32)
    }
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
                        if let dialogue = model.pet.dialogue {
                            SpeechBubble(text: dialogue)
                                .transition(.scale(scale: 0.8, anchor: .bottom).combined(with: .opacity))
                        }
                        PlaceholderCharacterView(action: model.pet.action, mood: model.pet.mood)
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

struct SettingsView: View {
    let model: AppModel

    @Environment(\.dismiss) private var dismiss
    @State private var confirmDelete = false
    @State private var busy = false
    @State private var error: String?

    var body: some View {
        NavigationStack {
            Form {
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
                    Button("Delete account", role: .destructive) { confirmDelete = true }
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
            .confirmationDialog("Delete your account?", isPresented: $confirmDelete, titleVisibility: .visible) {
                Button("Delete account", role: .destructive) {
                    Task {
                        busy = true
                        defer { busy = false }
                        do {
                            try await model.deleteAccount()
                            dismiss()
                        } catch {
                            self.error = AppModel.message(for: error)
                        }
                    }
                }
            } message: {
                Text("Your friend will be gone for good.")
            }
        }
    }
}
