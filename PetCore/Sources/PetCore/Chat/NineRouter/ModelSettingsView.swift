//
//  ModelSettingsView.swift
//  PetCore
//
//  Models (M37): where 9Router is, its optional key, the combo "Auto" means, a model for chat, explain and research,
//  and, for the models in use, how much to send and whether they see images. Picking a 9Router model the first time
//  says plainly where the text goes.
//

import SwiftUI

public struct ModelSettingsView: View {
    @Bindable var settings: ModelSettings
    @State private var key = ""
    @State private var testing = false
    @State private var status: String?
    /// A pick waiting for the privacy note to be read.
    @State private var pending: (feature: ModelFeature, choice: ModelChoice)?

    @MainActor public init(settings: ModelSettings? = nil) {
        self.settings = settings ?? .shared
    }

    public var body: some View {
        Form {
            Section {
                TextField("Address", text: $settings.baseURL, prompt: Text(NineRouter.defaultBaseURL.absoluteString))
                SecureField("API key (only if 9Router requires one)", text: $key)
                    .onSubmit { settings.apiKey = key }
                TextField("Auto uses the combo", text: $settings.autoCombo, prompt: Text("e.g. befriend-auto"))
                HStack {
                    Button(testing ? "Testing…" : "Test Connection", action: test).disabled(testing)
                    if let status { Text(status).font(.callout).foregroundStyle(.secondary).lineLimit(2) }
                }
            } header: {
                Text("9Router")
            } footer: {
                Text("9Router runs on this Mac and holds your provider keys. Set it up at [github.com/decolua/9router](https://github.com/decolua/9router).")
            }

            Section {
                ForEach(ModelFeature.allCases, id: \.self) { feature in
                    Picker(feature.title, selection: Binding(get: { settings.choice(for: feature) }, set: { pick($0, for: feature) })) {
                        Text("Apple (on this device)").tag(ModelChoice.apple)
                        Text(settings.autoCombo.isEmpty ? "Auto (name a combo above)" : "Auto · \(settings.autoCombo)").tag(ModelChoice.auto)
                            .disabled(settings.autoCombo.isEmpty)
                        if !settings.knownModels.isEmpty { Divider() }
                        ForEach(options(for: feature), id: \.self) { Text($0).tag(ModelChoice.model($0)) }
                    }
                }
            } header: {
                Text("Use for")
            } footer: {
                Text("With a 9Router model, a feature sends the conversation, files and question to that model in one go. Apple's model keeps everything on this Mac.")
            }

            if !inUse.isEmpty {
                Section("Models in use") {
                    ForEach(inUse, id: \.self) { model in
                        let limits = Binding(get: { settings.limits(for: model) }, set: { settings.setLimits($0, for: model) })
                        LabeledContent(model) {
                            HStack(spacing: 12) {
                                TextField("Tokens", value: limits.limit, format: .number).frame(width: 90).multilineTextAlignment(.trailing)
                                Toggle("Sees images", isOn: limits.seesImages)
                            }
                        }
                        .help("The most context sent to \(model) per request, in tokens")
                    }
                }
            }
        }
        .formStyle(.grouped)
        .onAppear { key = settings.apiKey }
        .onDisappear { settings.apiKey = key }
        .alert("Your messages go to the model's provider", isPresented: Binding(get: { pending != nil }, set: { if !$0 { pending = nil } })) {
            Button("Use It") {
                settings.privacyRead = true
                if let pending { settings.choose(pending.choice, for: pending.feature) }
                pending = nil
            }
            Button("Cancel", role: .cancel) { pending = nil }
        } message: {
            Text("""
                befriend sends the question, the conversation and the files you attached to 9Router on this Mac, which \
                passes them to the provider of the model you picked (unless 9Router runs it locally). Your keys stay in \
                9Router. Apple's model keeps everything on this Mac.
                """)
        }
    }

    /// The listed models, plus the one picked if 9Router no longer lists it.
    private func options(for feature: ModelFeature) -> [String] {
        var models = settings.knownModels
        if case .model(let picked) = settings.choice(for: feature), !models.contains(picked) { models.insert(picked, at: 0) }
        return models
    }

    /// The 9Router models some feature uses.
    private var inUse: [String] {
        var models: [String] = []
        for feature in ModelFeature.allCases {
            let name: String? = switch settings.choice(for: feature) {
            case .apple: nil
            case .auto: settings.autoCombo.isEmpty ? nil : settings.autoCombo
            case .model(let model): model
            }
            if let name, !models.contains(name) { models.append(name) }
        }
        return models
    }

    private func pick(_ choice: ModelChoice, for feature: ModelFeature) {
        guard choice != .apple, !settings.privacyRead else { return settings.choose(choice, for: feature) }
        pending = (feature, choice)
    }

    private func test() {
        settings.apiKey = key
        guard let config = settings.config else { status = "That address isn't a web address."; return }
        testing = true
        status = nil
        Task {
            do {
                let models = try await NineRouter(config).models()
                settings.knownModels = models
                status = models.isEmpty ? "Connected, but 9Router lists no models yet." : "Connected · \(models.count) models"
            } catch {
                status = error.localizedDescription
            }
            testing = false
        }
    }
}
