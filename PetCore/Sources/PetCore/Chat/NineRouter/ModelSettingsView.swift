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
                let router = NineRouter(config)
                let models = try await router.models()
                settings.remember(models)
                // Listing needs no key; answering might: one tiny request says whether it works.
                let probe = settings.model(for: .chat)?.name ?? (settings.autoCombo.isEmpty ? models.first?.id : settings.autoCombo)
                guard let probe else { status = "Connected, but 9Router lists no models yet."; testing = false; return }
                status = "Connected · \(models.count) models · asking \(probe)…"
                _ = try await router.respond([.init(.user, "Reply with the word OK.")], model: probe, maxTokens: 5)
                status = "Connected · \(models.count) models · \(probe) answers"
            } catch {
                status = error.localizedDescription
            }
            testing = false
        }
    }
}

/// The chat window's model, from its toolbar (M38): the same Chat choice as in Models, switched in place. Mac only,
/// like 9Router itself.
public struct ChatModelPicker: View {
    @Bindable var settings: ModelSettings
    @State private var pending: ModelChoice?

    @MainActor public init(settings: ModelSettings? = nil) {
        self.settings = settings ?? .shared
    }

    public var body: some View {
        Menu {
            Picker("Chat model", selection: Binding(get: { settings.choice(for: .chat) }, set: pick)) {
                Text("Apple (on this device)").tag(ModelChoice.apple)
                if !settings.autoCombo.isEmpty { Text("Auto · \(settings.autoCombo)").tag(ModelChoice.auto) }
                if !settings.knownModels.isEmpty { Divider() }
                ForEach(settings.knownModels, id: \.self) { Text($0).tag(ModelChoice.model($0)) }
            }
            .pickerStyle(.inline)
            if settings.knownModels.isEmpty {
                Text("Open Models… and Test Connection to list 9Router's models")
            }
        } label: {
            Label(label, systemImage: settings.choice(for: .chat) == .apple ? "cpu" : "network")
                .labelStyle(.titleAndIcon)
        }
        .fixedSize()
        .help("The model this chat answers with")
        .alert("Your messages go to the model's provider", isPresented: Binding(get: { pending != nil }, set: { if !$0 { pending = nil } })) {
            Button("Use It") {
                settings.privacyRead = true
                if let pending { settings.choose(pending, for: .chat) }
                pending = nil
            }
            Button("Cancel", role: .cancel) { pending = nil }
        } message: {
            Text("befriend sends the question, the conversation and its files to 9Router on this Mac, which passes them to the provider of the model you picked (unless 9Router runs it locally).")
        }
    }

    private var label: String {
        switch settings.choice(for: .chat) {
        case .apple: "On this Mac"
        case .auto: settings.autoCombo.isEmpty ? "Auto" : "Auto · \(settings.autoCombo)"
        case .model(let model): model
        }
    }

    private func pick(_ choice: ModelChoice) {
        guard choice != .apple, !settings.privacyRead else { return settings.choose(choice, for: .chat) }
        pending = choice
    }
}
