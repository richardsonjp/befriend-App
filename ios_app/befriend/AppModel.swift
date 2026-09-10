//
//  AppModel.swift
//  befriend
//

import Foundation
import Observation
import PetCore
import SwiftUI
import UIKit

extension DeviceInfo {
    static var current: DeviceInfo { DeviceInfo(platform: "ios", name: UIDevice.current.name) }
}

/// The app's state: where the account stands, and the friend once it's ready.
@Observable
final class AppModel {
    enum Phase: Equatable {
        case launching
        case signedOut
        case onboarding(QuestionSet)
        case hatching(name: String)
        case ready(FriendProfile)
    }

    private(set) var phase: Phase = .launching
    var errorMessage: String?
    /// A Mac pairing code from a scanned QR, shown once the friend is ready.
    var pendingPairingCode: String?
    let pet = PetStateMachine()

    @ObservationIgnored let api = AppConfig.makeAPIClient()
    @ObservationIgnored private var brain = PetBrain()
    @ObservationIgnored private var surfaces: SurfaceController!
    @ObservationIgnored private var hatchPoll: Task<Void, Never>?
    @ObservationIgnored private var backgroundedAt: Date?

    init() {
        surfaces = SurfaceController(api: api)
        PokeIntent.handler = { [weak self] in await self?.poke() }
    }

    var friend: FriendProfile? {
        if case .ready(let friend) = phase { friend } else { nil }
    }

    // MARK: Account

    func start() async {
        // Show the saved friend straight away; the server answer below corrects it if needed.
        if api.isSignedIn, let saved = SharedStore.loadFriend(), saved.isReady {
            adopt(saved)
        }
        await refresh()
    }

    /// Asks the server where the account stands: signed out, onboarding, hatching or ready.
    func refresh() async {
        guard api.isSignedIn else { return signedOut() }
        do {
            if let latest = try await api.friend() {
                if latest.isReady { adopt(latest) } else { startHatching(latest) }
            } else {
                phase = .onboarding(try await api.questions())
            }
            errorMessage = nil
        } catch APIError.signedOut {
            signedOut()
        } catch {
            // Offline with a saved friend: keep showing it.
            if friend == nil { errorMessage = Self.message(for: error) }
        }
    }

    /// Runs a sign-in call, then moves on to wherever the account stands.
    func signIn(_ action: () async throws -> Void) async {
        errorMessage = nil
        do {
            try await action()
            await refresh()
        } catch {
            errorMessage = Self.message(for: error)
        }
    }

    func completeOnboarding(_ payload: CompleteOnboarding) async throws {
        let created = try await api.completeOnboarding(payload)
        if created.isReady { adopt(created) } else { startHatching(created) }
    }

    func signOut() async {
        await api.logout()
        signedOut()
    }

    func deleteAccount() async throws {
        try await api.deleteAccount()
        signedOut()
    }

    private func signedOut() {
        hatchPoll?.cancel()
        SharedStore.saveFriend(nil)
        surfaces.signedOut()
        brain = PetBrain()
        phase = .signedOut
    }

    func handleDeepLink(_ url: URL) {
        guard url.scheme == "befriend", url.host() == "pair",
              let code = URLComponents(url: url, resolvingAgainstBaseURL: false)?
                .queryItems?.first(where: { $0.name == "code" })?.value,
              !code.isEmpty else { return }
        pendingPairingCode = code
    }

    // MARK: Friend

    private func adopt(_ latest: FriendProfile) {
        hatchPoll?.cancel()
        let isNewVersion = friend?.personality.version != latest.personality.version
        SharedStore.saveFriend(latest)
        phase = .ready(latest)
        if isNewVersion {
            brain = PetBrain(friend: latest)
            brain.onReaction = { [weak self] in self?.show($0) }
            let hello = brain.quickReaction(to: .returned(afterSeconds: 0))
            show(hello)
            surfaces.friendReady(latest, state: FriendSurfaceState(presence: .here, mood: hello.mood, action: hello.action, line: hello.dialogue))
        }
    }

    private func startHatching(_ hatching: FriendProfile) {
        phase = .hatching(name: hatching.name)
        hatchPoll?.cancel()
        hatchPoll = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(3))
                guard let self, case .hatching = self.phase else { return }
                if let latest = try? await self.api.friend(), latest.isReady {
                    self.adopt(latest)
                    return
                }
            }
        }
    }

    func poke() async {
        adoptSavedFriendIfNeeded() // a Dynamic Island tap can launch the app without its window
        guard friend != nil else { return }
        show(brain.quickReaction(to: .poked, mood: pet.mood))
        show(await brain.react(to: .poked))
    }

    private func show(_ reaction: PetReaction) {
        pet.apply(reaction)
        surfaces.update(with: reaction)
    }

    func scenePhaseChanged(_ scenePhase: ScenePhase) {
        guard let current = friend else { return }
        switch scenePhase {
        case .active:
            let away = backgroundedAt.map { Date.now.timeIntervalSince($0) } ?? 0
            backgroundedAt = nil
            brain.handle(.returned(afterSeconds: away))
            Task {
                if let latest = try? await api.friend(), latest.isReady, latest.personality.version != current.personality.version {
                    adopt(latest)
                }
            }
        case .background:
            backgroundedAt = .now
            show(brain.quickReaction(to: .leftApp, mood: pet.mood))
            CheckIn.schedule()
        default:
            break
        }
    }

    /// Hourly background refresh: the friend checks in on the Lock Screen and widget.
    func checkIn() async {
        defer { CheckIn.schedule() }
        adoptSavedFriendIfNeeded() // launched in the background
        guard friend != nil else { return }
        show(await brain.react(to: .checkIn))
    }

    /// Background launches (refresh, intents) skip the window's start(): bring back the saved friend.
    private func adoptSavedFriendIfNeeded() {
        if friend == nil, api.isSignedIn, let saved = SharedStore.loadFriend(), saved.isReady {
            adopt(saved)
        }
    }

    static func message(for error: Error) -> String {
        switch error {
        case APIError.server(_, "VALIDATION_FAILED", _): "Please check what you entered."
        case APIError.server(_, _, let message) where !message.isEmpty: message
        case is URLError: "Can't reach befriend right now. Check your connection."
        default: "Something went wrong. Please try again."
        }
    }
}
