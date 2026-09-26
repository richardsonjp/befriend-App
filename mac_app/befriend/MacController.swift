//
//  MacController.swift
//  befriend
//

import AppKit
import AuthenticationServices
import GoogleSignIn
import Observation
import PetCore
import SwiftUI

/// The Mac app's flow: sign in (QR pairing first), wait for the friend to hatch on iPhone, then run the friend.
@Observable
final class MacController {
    enum Stage: Equatable {
        case launching
        case signedOut
        case waitingForFriend
        case ready
    }

    private static let pairingPollInterval: Duration = .seconds(2)
    private static let friendPollInterval: Duration = .seconds(5)
    private static let settingsRetryInterval: Duration = .seconds(60)
    private static let personalityRefreshInterval: Duration = .seconds(6 * 60 * 60)
    /// How long the friend lingers to say its focus line before walking home.
    private static let goodbyeDuration: TimeInterval = 3

    private(set) var stage: Stage = .launching
    private(set) var pairing: PairingStart?
    private(set) var settings = SyncSettings()
    private(set) var frontmostApp: String?
    var errorMessage: String?
    let pet = PetStateMachine()
    /// The account's skin; a pick made on the iPhone arrives over the presence socket.
    let skins = SkinStore(root: MacConfig.skinsRoot)
    /// Walks the friend between the menu bar icon and the screen.
    let walker = FriendWalker()
    /// During focus the friend stays in the menu bar icon unless let out.
    let pomodoro = PomodoroRunner(saved: MacConfig.loadPomodoro(), save: MacConfig.savePomodoro)

    @ObservationIgnored let api = MacConfig.makeAPIClient()
    @ObservationIgnored private let uploader: TriggerLogUploader
    @ObservationIgnored private var brain = PetBrain()
    @ObservationIgnored private var friend: FriendProfile?
    @ObservationIgnored private var panel: PetPanel?
    @ObservationIgnored private var monitor: TriggerMonitor?
    @ObservationIgnored private var window: NSWindow?
    @ObservationIgnored private var windowCloseObserver: NSObjectProtocol?
    @ObservationIgnored private var pairingTask: Task<Void, Never>?
    @ObservationIgnored private var friendPoll: Task<Void, Never>?
    @ObservationIgnored private var backgroundRefresh: Task<Void, Never>?
    @ObservationIgnored private var presence: PresenceReporter?
    @ObservationIgnored private var peer: PresencePeer?
    @ObservationIgnored private var phoneClaimedNearby = false
    @ObservationIgnored private var friendVisible = true
    /// The latest reaction that arrived while the friend was walking or away.
    @ObservationIgnored private var heldReaction: PetReaction?
    /// The friend says its focus line before going home; the pomodoro keeps it out until then.
    @ObservationIgnored private var goodbyeUntil = Date.distantPast

    init() {
        uploader = TriggerLogUploader(api: api, fileURL: MacConfig.triggerQueueURL)
        pomodoro.onPhaseEnded = MacPomodoro.announce
        pomodoro.onMoment = { [weak self] in self?.pomodoroMoment($0) }
        if let saved = MacConfig.loadSettings() { apply(saved) }
    }

    // MARK: Flow

    func start() async {
        guard api.isSignedIn else { return showSignIn() }
        if let saved = MacConfig.loadFriend(), saved.isReady {
            becomeReady(saved) // straight away; the server check below updates it
        }
        await checkFriend()
    }

    /// Where a signed-in account stands: a ready friend runs, anything else waits for the iPhone.
    private func checkFriend() async {
        do {
            if let latest = try await api.friend(), latest.isReady {
                becomeReady(latest)
            } else if stage != .ready {
                showWaiting()
            }
        } catch APIError.signedOut {
            signedOut()
        } catch {
            if stage != .ready { showWaiting() } // offline without a saved friend: keep polling
        }
    }

    /// The menu's Sign In… / Show Setup…: reopens the window for whatever stage we're in.
    func reopenWindow() {
        if api.isSignedIn {
            if stage != .ready { showWindow() }
        } else {
            showSignIn()
        }
    }

    private func showSignIn() {
        stage = .signedOut
        showWindow()
        startPairing()
    }

    private func showWaiting() {
        stage = .waitingForFriend
        pairingTask?.cancel()
        showWindow()
        guard friendPoll == nil else { return }
        friendPoll = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.friendPollInterval)
                guard let self, self.stage == .waitingForFriend else { break }
                await self.checkFriend()
            }
            self?.friendPoll = nil
        }
    }

    private func signedIn() async {
        pairingTask?.cancel()
        pairing = nil
        errorMessage = nil
        await checkFriend()
    }

    private func becomeReady(_ latest: FriendProfile) {
        friendPoll?.cancel()
        friendPoll = nil
        pairingTask?.cancel()
        closeWindow()
        let isNewVersion = friend?.personality.version != latest.personality.version
        friend = latest
        MacConfig.saveFriend(latest)
        stage = .ready

        if isNewVersion {
            brain = PetBrain(friend: latest)
            brain.onReaction = { [weak self] in self?.show($0) }
            brain.context = { [pomodoro] in pomodoro.state.promptContext(at: .now) }
            brain.skin = { [skins] in skins.current?.vocabulary ?? (PetAction.builtIn, PetMood.builtIn) }
        }
        guard panel == nil else { return }

        let panel = PetPanel { [pet, skins, walker] panel in
            PetView(
                pet: pet, skins: skins, walker: walker,
                poke: { [weak self] in self?.handle(.poked) },
                simulate: { [weak self] in self?.handle($0) },
                reportHitAreas: { [weak panel] in panel?.hitAreas = $0 }
            )
        }
        self.panel = panel
        walker.panel = panel
        walker.canWander = { [pet] in pet.action == .idle && pet.dialogue == nil }
        walker.onSettled = { [weak self] in self?.showHeldReaction() }
        pomodoro.onChange = { [weak self] in self?.updateVisibility() }
        // A focus phase that outlived a relaunch or sign-out keeps the friend home.
        friendVisible = !pomodoro.state.friendHome
        if friendVisible { walker.comeOut() }

        let presence = PresenceReporter(api: api)
        presence.onChange = { [weak self] in self?.updateVisibility() }
        presence.onSkinChanged = { [weak self] in self?.syncSkins() }
        presence.start()
        self.presence = presence
        Task { [weak self] in
            guard let self, let me = try? await self.api.me() else { return }
            self.startPeer(userID: me.id)
        }

        let monitor = TriggerMonitor(onIdleReading: { [weak self] in self?.presence?.update(idleSeconds: $0) }) { [weak self] in
            self?.handle($0)
        }
        monitor.start()
        self.monitor = monitor
        uploader.start()
        show(brain.quickReaction(to: .returned(afterSeconds: 0)))

        backgroundRefresh = Task { [weak self] in
            await self?.refreshSettingsUntilLoaded()
            while !Task.isCancelled {
                if let self { await self.skins.sync(api: self.api) }
                try? await Task.sleep(for: Self.personalityRefreshInterval)
                await self?.checkFriend()
                await self?.refreshSettingsUntilLoaded()
            }
        }
    }

    private func handle(_ trigger: Trigger) {
        if case .appSwitched(let name) = trigger { frontmostApp = name }
        uploader.record(trigger)
        if friendVisible { brain.handle(trigger) }
    }

    /// Reactions wait while the friend walks or hops, so its bubble never trails half off screen; the latest one
    /// plays once it stands still.
    private func show(_ reaction: PetReaction) {
        guard friendVisible else { return } // finished generating after the friend left: stale by the time it's back
        if walker.place == .out {
            pet.apply(reaction)
        } else {
            heldReaction = reaction
        }
    }

    /// Heading home for focus: a quick line first, then the walk. Otherwise the friend reacts as usual (held while
    /// it comes out for the break).
    private func pomodoroMoment(_ moment: PomodoroMoment) {
        let trigger = Trigger.pomodoro(moment)
        guard pomodoro.state.friendHome else { return brain.handle(trigger) }
        guard friendVisible, walker.place == .out else { return }
        pet.apply(brain.quickReaction(to: trigger))
        goodbyeUntil = .now + Self.goodbyeDuration
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(Self.goodbyeDuration))
            self?.updateVisibility()
        }
    }

    private func showHeldReaction() {
        guard let reaction = heldReaction else { return }
        heldReaction = nil
        pet.apply(reaction)
    }

    /// A skin switch that landed comes with lines written for it: fetch the friend too.
    private func syncSkins() {
        Task { [weak self] in
            guard let self else { return }
            let before = self.skins.current
            await self.skins.sync(api: self.api)
            if self.skins.current != before { await self.checkFriend() }
        }
    }

    // MARK: Presence

    private func startPeer(userID: String) {
        guard peer == nil, stage == .ready else { return }
        let peer = PresencePeer(userID: userID, displayName: MacConfig.device.name)
        peer.onMessage = { [weak self] message in
            self?.phoneClaimedNearby = message == .claim
            self?.updateVisibility()
        }
        peer.start()
        self.peer = peer
    }

    /// Shows the friend only where it is (see PresenceVisibility) and not while it's home for a focus phase: it comes
    /// out of the menu bar icon, or goes back in, straight away if the screen is locked or asleep.
    private func updateVisibility() {
        guard panel != nil, let presence else { return }
        if presence.owner == .phone { phoneClaimedNearby = false } // the backend caught up with the nearby claim
        let show = PresenceVisibility.macShowsFriend(
            isActive: presence.isActive,
            owner: presence.owner,
            socketConnected: presence.isConnected,
            phoneClaimedNearby: phoneClaimedNearby
        ) && !(pomodoro.state.friendHome && Date.now >= goodbyeUntil)
        guard show != friendVisible else { return }
        friendVisible = show
        if show {
            walker.comeOut()
        } else {
            heldReaction = nil
            walker.goHome(instant: presence.screenUnavailable)
        }
    }

    // MARK: Pairing

    private func startPairing() {
        pairingTask?.cancel()
        pairingTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                do {
                    let start = try await self.api.startPairing(deviceName: MacConfig.device.name)
                    self.pairing = start
                    self.errorMessage = nil
                    while Date.now < start.expiresAt {
                        try await Task.sleep(for: Self.pairingPollInterval)
                        if try await self.api.claimPairing(code: start.code, pollSecret: start.pollSecret) == .signedIn {
                            await self.signedIn()
                            return
                        }
                    }
                } catch is CancellationError {
                    return
                } catch APIError.server(status: 410, _, _) {
                    continue // expired or used: show a fresh code
                } catch {
                    self.pairing = nil
                    self.errorMessage = "Can't reach befriend. Trying again…"
                    try? await Task.sleep(for: .seconds(5))
                }
            }
        }
    }

    // MARK: Other sign-in methods

    func appleSignInCompleted(_ result: Result<ASAuthorization, Error>, nonce: String) async {
        switch result {
        case .failure(let error):
            if (error as? ASAuthorizationError)?.code != .canceled {
                errorMessage = "Sign in with Apple didn't finish. Please try again."
            }
        case .success(let authorization):
            guard let credential = authorization.credential as? ASAuthorizationAppleIDCredential,
                  let tokenData = credential.identityToken,
                  let identityToken = String(data: tokenData, encoding: .utf8) else {
                errorMessage = "Sign in with Apple didn't finish. Please try again."
                return
            }
            let code = credential.authorizationCode.flatMap { String(data: $0, encoding: .utf8) }
            await signIn {
                try await self.api.signInWithApple(identityToken: identityToken, authorizationCode: code, nonce: nonce, device: MacConfig.device)
            }
        }
    }

    func signInWithGoogle() async {
        guard !MacConfig.googleClientID.isEmpty else {
            errorMessage = "Google sign-in isn't set up in this build."
            return
        }
        guard let window else { return }
        let nonce = Nonce.random()
        do {
            let result = try await GIDSignIn.sharedInstance.signIn(withPresenting: window, hint: nil, additionalScopes: nil, nonce: nonce)
            guard let idToken = result.user.idToken?.tokenString else { return }
            await signIn {
                try await self.api.signInWithGoogle(idToken: idToken, nonce: nonce, device: MacConfig.device)
            }
        } catch {
            if (error as NSError).code != GIDSignInError.canceled.rawValue {
                errorMessage = "Google sign-in didn't finish. Please try again."
            }
        }
    }

    func signInWithEmail(email: String, password: String) async {
        await signIn {
            try await self.api.login(email: email, password: password, device: MacConfig.device)
        }
    }

    private func signIn(_ action: () async throws -> Void) async {
        errorMessage = nil
        do {
            try await action()
            await signedIn()
        } catch APIError.server(status: 401, _, _) {
            errorMessage = "Those details didn't work. New here? Create your account on iPhone first."
        } catch {
            errorMessage = "Can't sign in right now. Please try again."
        }
    }

    // MARK: Menu actions

    /// Settings decide what gets recorded, so keep asking until the server answers (the saved copy applies meanwhile).
    private func refreshSettingsUntilLoaded() async {
        while !Task.isCancelled {
            if let latest = try? await api.syncSettings() {
                apply(latest)
                return
            }
            try? await Task.sleep(for: Self.settingsRetryInterval)
        }
    }

    func togglePause() async {
        await updateSettings { try await self.api.updateSyncSettings(paused: !self.settings.logSyncPaused) }
    }

    func stopTrackingFrontmostApp() async {
        guard let app = frontmostApp else { return }
        await updateSettings { try await self.api.updateSyncSettings(excludedApps: self.settings.excludedApps + [app]) }
    }

    /// Picks the account's skin (nil = the built-in one); the iPhone follows.
    func selectSkin(_ id: String?) async {
        do {
            try await skins.select(id, api: api)
        } catch {
            NSSound.beep()
        }
    }

    func deleteActivity() async {
        do {
            try await api.deleteTriggerEvents()
            uploader.clear()
        } catch {
            NSSound.beep()
        }
    }

    func signOut() async {
        await api.logout()
        signedOut()
    }

    private func updateSettings(_ change: () async throws -> SyncSettings) async {
        do {
            apply(try await change())
        } catch {
            NSSound.beep()
        }
    }

    private func apply(_ latest: SyncSettings) {
        settings = latest
        uploader.settings = latest
        MacConfig.saveSettings(latest)
    }

    private func signedOut() {
        friendPoll?.cancel()
        friendPoll = nil
        backgroundRefresh?.cancel()
        presence?.stop()
        presence = nil
        peer?.stop()
        peer = nil
        phoneClaimedNearby = false
        uploader.stop()
        uploader.clear()
        monitor?.stop()
        monitor = nil
        walker.goHome(instant: true)
        heldReaction = nil
        panel?.close()
        panel = nil
        friend = nil
        brain = PetBrain()
        pet.apply(PetReaction(action: .idle, mood: .content, dialogue: ""))
        skins.reset()
        apply(SyncSettings())
        MacConfig.saveSettings(nil)
        MacConfig.saveFriend(nil)
        showSignIn()
    }

    // MARK: Window

    private func showWindow() {
        if window == nil {
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 420, height: 600),
                styleMask: [.titled, .closable],
                backing: .buffered,
                defer: false
            )
            window.title = "befriend"
            window.isReleasedWhenClosed = false
            window.contentView = NSHostingView(rootView: MacWindowView(controller: self))
            window.center()
            windowCloseObserver = NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.windowClosed() }
            }
            self.window = window
        }
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
    }

    /// The user closed the window: stop generating pairing codes until they reopen it from the menu.
    private func windowClosed() {
        pairingTask?.cancel()
        pairing = nil
        if let windowCloseObserver { NotificationCenter.default.removeObserver(windowCloseObserver) }
        windowCloseObserver = nil
        window = nil
    }

    private func closeWindow() {
        window?.close() // posts willClose → windowClosed()
    }
}
