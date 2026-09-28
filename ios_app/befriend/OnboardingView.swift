//
//  OnboardingView.swift
//  befriend
//

import PetCore
import SwiftUI

/// The questionnaire, then the friend's birthplace, the data-sharing consent and cat or dog, then hatching.
struct OnboardingView: View {
    let model: AppModel
    let questions: QuestionSet

    private enum Stage: Hashable { case question(Int), birthplace, consent, species }

    @State private var stage = Stage.question(0)
    @State private var texts: [String: String] = [:]
    @State private var choices: [String: String] = [:]
    @State private var sliders: [String: Double] = [:]
    @State private var location = LocationFetcher()
    @State private var consent = false
    @State private var species: String?
    @State private var submitting = false
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            ProgressView(value: progress)
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    switch stage {
                    case .question(let index): questionView(questions.questions[index])
                    case .birthplace: birthplaceView
                    case .consent: consentView
                    case .species: speciesView
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            if let error {
                Text(error).font(.footnote).foregroundStyle(.red)
            }
            HStack {
                if stage != .question(0) {
                    Button("Back", action: back).disabled(submitting)
                }
                Spacer()
                Button(stage == .species ? "Hatch my friend" : "Next", action: next)
                    .buttonStyle(.borderedProminent)
                    .disabled(!canContinue || submitting)
            }
            .controlSize(.large)
        }
        .padding(24)
        .animation(.snappy, value: stage)
    }

    // MARK: Stages

    @ViewBuilder
    private func questionView(_ question: Question) -> some View {
        Text(question.prompt).font(.title2.bold())
        switch question.type {
        case .text:
            let limit = question.maxLength ?? 24
            TextField("Your answer", text: binding(for: question.id, limit: limit))
                .textFieldStyle(.roundedBorder)
                .submitLabel(.next)
                .onSubmit { if canContinue { next() } }
            Text("\(texts[question.id, default: ""].count)/\(limit)")
                .font(.caption).foregroundStyle(.secondary)
        case .choice:
            ForEach(question.options ?? [], id: \.self) { option in
                Button {
                    choices[question.id] = option
                } label: {
                    HStack {
                        Text(option)
                        Spacer()
                        if choices[question.id] == option { Image(systemName: "checkmark.circle.fill") }
                    }
                    .padding()
                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 12))
                }
                .buttonStyle(.plain)
            }
        case .slider:
            let range = Double(question.min ?? 1)...Double(question.max ?? 10)
            Slider(value: sliderBinding(for: question.id, range: range), in: range, step: 1)
            HStack {
                Text(question.minLabel ?? "\(Int(range.lowerBound))")
                Spacer()
                Text(question.maxLabel ?? "\(Int(range.upperBound))")
            }
            .font(.caption).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var birthplaceView: some View {
        Text("Where is your friend being born?").font(.title2.bold())
        Text("Your friend's birthplace and birth moment shape its star sign and element. We only keep the city.")
            .foregroundStyle(.secondary)
        if let place = location.place {
            Label(place.city ?? "Near you", systemImage: "mappin.and.ellipse")
                .font(.headline)
        } else {
            Button {
                location.request()
            } label: {
                Label(location.isLocating ? "Finding you…" : "Use my approximate location", systemImage: "location")
            }
            .buttonStyle(.bordered)
            .disabled(location.isLocating)
        }
        if let status = location.status {
            Text(status).font(.footnote).foregroundStyle(.secondary)
        }
        Text("You can also skip this; your time zone is used instead.")
            .font(.footnote).foregroundStyle(.secondary)
    }

    @ViewBuilder
    private var consentView: some View {
        Text("Before your friend hatches").font(.title2.bold())
        Text("""
            To create and grow your friend, befriend sends your answers to our server, and our server sends them to \
            a third-party AI provider. Once you connect your Mac, the apps you switch between and when you're away \
            are synced too, and the recent activity is sent to that AI provider each week so your friend can evolve. \
            You can pause syncing, exclude apps or delete your activity at any time in Settings.
            """)
        Toggle("I understand and agree", isOn: $consent)
            .font(.headline)
    }

    @ViewBuilder
    private var speciesView: some View {
        Text("Cat or dog?").font(.title2.bold())
        Text("Pick how your friend looks. Its personality comes from your answers either way.")
            .foregroundStyle(.secondary)
        HStack(spacing: 16) {
            speciesCard("cat", title: "Cat", image: "SpeciesCat")
            speciesCard("dog", title: "Dog", image: "SpeciesDog")
        }
    }

    private func speciesCard(_ id: String, title: String, image: String) -> some View {
        Button {
            species = id
        } label: {
            VStack(spacing: 12) {
                Image(image).interpolation(.none).resizable().scaledToFit().frame(width: 96, height: 96)
                Text(title).font(.headline)
            }
            .frame(maxWidth: .infinity)
            .padding()
            .background(.quaternary, in: RoundedRectangle(cornerRadius: 16))
            .overlay {
                RoundedRectangle(cornerRadius: 16).strokeBorder(.tint, lineWidth: species == id ? 3 : 0)
            }
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(species == id ? .isSelected : [])
    }

    // MARK: Navigation

    private var progress: Double {
        let total = Double(questions.questions.count + 3)
        return switch stage {
        case .question(let index): Double(index) / total
        case .birthplace: Double(questions.questions.count) / total
        case .consent: Double(questions.questions.count + 1) / total
        case .species: Double(questions.questions.count + 2) / total
        }
    }

    private var canContinue: Bool {
        switch stage {
        case .question(let index):
            let question = questions.questions[index]
            return switch question.type {
            case .text: !texts[question.id, default: ""].trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            case .choice: choices[question.id] != nil
            case .slider: true
            }
        case .birthplace:
            return !location.isLocating
        case .consent:
            return consent
        case .species:
            return species != nil
        }
    }

    private func next() {
        error = nil
        switch stage {
        case .question(let index):
            stage = index + 1 < questions.questions.count ? .question(index + 1) : .birthplace
        case .birthplace:
            stage = .consent
        case .consent:
            stage = .species
        case .species:
            Task { await submit() }
        }
    }

    private func back() {
        switch stage {
        case .question(let index): stage = .question(max(0, index - 1))
        case .birthplace: stage = .question(questions.questions.count - 1)
        case .consent: stage = .birthplace
        case .species: stage = .consent
        }
    }

    private func submit() async {
        submitting = true
        defer { submitting = false }
        let answers = questions.questions.map { question in
            switch question.type {
            case .text:
                OnboardingAnswer(questionId: question.id, value: .text(texts[question.id, default: ""].trimmingCharacters(in: .whitespacesAndNewlines)))
            case .choice:
                OnboardingAnswer(questionId: question.id, value: .text(choices[question.id] ?? ""))
            case .slider:
                OnboardingAnswer(questionId: question.id, value: .number(Int(sliders[question.id] ?? defaultSlider(question))))
            }
        }
        do {
            try await model.completeOnboarding(CompleteOnboarding(
                questionSetVersion: questions.version,
                answers: answers,
                timezone: TimeZone.current.identifier,
                location: location.place,
                consent: consent,
                species: species
            ))
        } catch {
            self.error = AppModel.message(for: error)
        }
    }

    // MARK: Bindings

    private func binding(for id: String, limit: Int) -> Binding<String> {
        Binding(
            get: { texts[id, default: ""] },
            set: { texts[id] = String($0.prefix(limit)) }
        )
    }

    private func sliderBinding(for id: String, range: ClosedRange<Double>) -> Binding<Double> {
        Binding(
            get: { sliders[id] ?? ((range.lowerBound + range.upperBound) / 2).rounded() },
            set: { sliders[id] = $0 }
        )
    }

    private func defaultSlider(_ question: Question) -> Double {
        ((Double(question.min ?? 1) + Double(question.max ?? 10)) / 2).rounded()
    }
}
