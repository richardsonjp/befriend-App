//
//  befriendApp.swift
//  befriend
//

import GoogleSignIn
import PetCore
import SwiftUI

@main
struct befriendApp: App {
    @State private var model = AppModel()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            RootView(model: model)
                .onOpenURL { url in
                    if GIDSignIn.sharedInstance.handle(url) { return }
                    model.handleDeepLink(url) // befriend://pair?code=… from the Mac's QR
                }
                .task { await model.start() }
        }
        .onChange(of: scenePhase) { _, phase in
            model.scenePhaseChanged(phase)
        }
        .backgroundTask(.appRefresh(CheckIn.taskIdentifier)) {
            await model.checkIn()
        }
    }
}

struct RootView: View {
    let model: AppModel

    var body: some View {
        switch model.phase {
        case .launching:
            VStack(spacing: 16) {
                if let error = model.errorMessage {
                    Text(error).multilineTextAlignment(.center)
                    Button("Try again") { Task { await model.refresh() } }
                        .buttonStyle(.borderedProminent)
                } else {
                    ProgressView()
                }
            }
            .padding()
        case .signedOut:
            SignInView(model: model)
        case .onboarding(let questions):
            OnboardingView(model: model, questions: questions)
        case .hatching(let name):
            HatchingView(name: name)
        case .ready(let friend):
            HomeView(model: model, friend: friend)
        }
    }
}
