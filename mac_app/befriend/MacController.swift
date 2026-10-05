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
    /// The longest the friend waits for its focus-start line before heading home anyway.
    private static let goodbyeWait: TimeInterval = 10

    private(set) var stage: Stage = .launching
    private(set) var pairing: PairingStart?
    /// Chat sync (M23), once the account is known.
    private(set) var chatSync: ChatSync?
    /// Rides along in the sign-in QR code, so the iPhone can hand over the chat key as it pairs this Mac.
    @ObservationIgnored private var pairingInvitation: (invitation: ChatCrypto.Invitation, party: ChatCrypto.Party)?
    @ObservationIgnored private var chatSyncLoop: Task<Void, Never>?
    private static let chatSyncInterval: Duration = .seconds(60)

    /// The sign-in code as a link: the pairing code plus the chat-key invitation.
    var pairingURL: URL? {
        guard let pairing else { return nil }
        var components = URLComponents(url: pairing.url, resolvingAgainstBaseURL: false)
        if pairingInvitation == nil {
            let party = ChatCrypto.Party()
            pairingInvitation = (ChatCrypto.newInvitation(party), party)
        }
        let items = (components?.queryItems ?? []) + (pairingInvitation?.invitation.queryItems ?? [])
        components?.queryItems = items
        return components?.url ?? pairing.url
    }
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
    /// Records each focus as a 1-minute timelapse when the pomodoro's setting is on (M11).
    @ObservationIgnored private(set) lazy var timelapse = TimelapseController(
        library: TimelapseLibrary(folder: MacConfig.timelapseFolder),
        skin: { [weak self] in self?.skins.current }
    )
    /// Local chat about the user's files (M18); only on this device.
    @ObservationIgnored private(set) lazy var chat = ChatLibrary()
    /// Explain part of the screen (M31): its shortcut, the capture and the explanation.
    @ObservationIgnored private(set) lazy var screenExplain = ScreenExplainFlow(
        library: chat, friend: { [weak self] in self?.friend }, openChat: { [weak self] in self?.openChat($0) },
        friendVisit: { [weak self] card in
            guard let self, self.friendVisible else { return }
            self.walker.visit(beside: card)
            self.pet.apply(PetReaction(action: .think, mood: self.pet.mood, dialogue: ""))
        },
        friendDone: { [weak self] in
            guard let self, self.pet.action == .think else { return }
            self.pet.apply(PetReaction(action: .idle, mood: self.pet.mood, dialogue: ""))
        })
    /// Green/red posture light (M14), sharing the timelapse camera; paused while the Mac sleeps or is locked.
    @ObservationIgnored private(set) lazy var posture: PostureChecker = {
        let checker = PostureChecker(camera: timelapse.recorder.camera)
        checker.onNudge = { [weak self] in self?.postureNudge() }
        return checker
    }()
    @ObservationIgnored private var sleepObservers: [NSObjectProtocol] = []
    /// Paid skins; a purchase unlocks the skin for the account on every device.
    @ObservationIgnored private(set) lazy var shop: SkinShop = {
        let shop = SkinShop(api: api)
        shop.onUnlocked = { [weak self] in self?.syncSkins() }
        return shop
    }()

    @ObservationIgnored let api = MacConfig.makeAPIClient()
    @ObservationIgnored private let uploader: TriggerLogUploader
    @ObservationIgnored private var brain = PetBrain()
    @ObservationIgnored private(set) var friend: FriendProfile?
    /// Opens Chat where a follow-up points (M19).
    let chatNavigator = ChatNavigator()
    /// Shows the Chat window; the status menu owns it.
    @ObservationIgnored var showChatWindow: () -> Void = {}
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
    /// The user sent the friend home: it stays in until they let it out or a focus ends, through idle, wake,
    /// unlock, the iPhone letting go, network drops and relaunches.
    private(set) var sentHome = UserDefaults.standard.bool(forKey: MacController.sentHomeKey) {
        didSet { UserDefaults.standard.set(sentHome, forKey: Self.sentHomeKey) }
    }
    private static let sentHomeKey = "friend.sentHome"
    /// Whether a focus was under way at the last pomodoro change, to notice it ending.
    @ObservationIgnored private var wasFocusing = false
    /// The latest reaction that arrived while the friend was walking or away.
    @ObservationIgnored private var heldReaction: PetReaction?
    /// The friend says its focus line before going home; the pomodoro keeps it out until then.
    @ObservationIgnored private var goodbyeUntil = Date.distantPast

    init() {
        uploader = TriggerLogUploader(api: api, fileURL: MacConfig.triggerQueueURL)
        // Code answers are compiled and run on Compiler Explorer through the backend (M40).
        CodeCheck.checker = { [api] language, source in try await api.checkCode(language: language, source: source) }
        pomodoro.onFocusEnded = MacPomodoro.announce
        pomodoro.onMoment = { [weak self] in self?.pomodoroMoment($0) }
        shop.start()
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
            brain.chatExchanges = { [weak self] in self?.chat.recentExchanges() ?? [] }
            timelapse.title = { [weak self] context in await self?.brain.timelapseTitle(for: context) }
        }
        guard panel == nil else { return }

        let panel = PetPanel { [pet, skins, walker] panel in
            PetView(
                pet: pet, skins: skins, walker: walker,
                poke: { [weak self] in self?.handle(.poked) },
                simulate: { [weak self] in self?.handle($0) },
                openChat: { [weak self] in self?.openChat($0) },
                goHome: { [weak self] in self?.sendHome() },
                explainScreen: { [weak self] in self?.screenExplain.begin() },
                reportHitAreas: { [weak panel] in panel?.hitAreas = $0 }
            )
        }
        self.panel = panel
        walker.panel = panel
        walker.canWander = { [pet] in pet.action == .idle && pet.dialogue == nil }
        walker.onSettled = { [weak self] in self?.showHeldReaction() }
        wasFocusing = pomodoro.state.status != .ready
        pomodoro.onChange = { [weak self] in
            guard let self else { return }
            // A focus ending (or stopped) lets the friend out, even if it was sent home.
            let focusing = self.pomodoro.state.status != .ready
            if self.wasFocusing, !focusing { self.sentHome = false }
            self.wasFocusing = focusing
            self.updateVisibility()
            self.timelapse.sync(self.pomodoro.state)
        }
        observeSleep()
        timelapse.setSignedIn(true)
        _ = posture // turns itself back on if it was on
        screenExplain.start()
        // A focus that outlived a relaunch or sign-out keeps the friend home, and so does having been sent home.
        friendVisible = PresenceVisibility.friendShows(presenceShows: true, focusHome: pomodoro.state.friendHome,
                                                       inGoodbye: false, sentHome: sentHome)
        if friendVisible { walker.comeOut() }

        let presence = PresenceReporter(api: api)
        presence.onChange = { [weak self] in self?.updateVisibility() }
        presence.onSkinChanged = { [weak self] in self?.syncSkins() }
        presence.start()
        self.presence = presence
        Task { [weak self] in
            guard let self, let me = try? await self.api.me() else { return }
            self.startPeer(userID: me.id)
            self.startChatSync(userID: me.id)
        }

        let monitor = TriggerMonitor(onIdleReading: { [weak self] in self?.presence?.update(idleSeconds: $0) }) { [weak self] in
            self?.handle($0)
        }
        monitor.start()
        self.monitor = monitor
        uploader.start()
        show(brain.quickReaction(to: .returned(afterSeconds: 0)))

        backgroundRefresh = Task { [weak self] in
            await self?.shop.load()
            await self?.refreshSettingsUntilLoaded()
            while !Task.isCancelled {
                if let self { await self.skins.sync(api: self.api) }
                try? await Task.sleep(for: Self.personalityRefreshInterval)
                await self?.checkFriend()
                await self?.refreshSettingsUntilLoaded()
            }
        }
    }

    /// App switches still feed activity sync and "Stop Tracking", but the friend no longer comments on them (M17).
    private func handle(_ trigger: Trigger) {
        if case .appSwitched(let name) = trigger { frontmostApp = name }
        uploader.record(trigger)
        if friendVisible, trigger.kind != .appSwitched { brain.handle(trigger) }
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
        goodbyeUntil = .now + Self.goodbyeWait // stays out while the model writes its line
        Task { [weak self] in
            guard let self else { return }
            let line = await brain.react(to: trigger)
            if friendVisible { pet.apply(line) }
            goodbyeUntil = .now + Self.goodbyeDuration
            try? await Task.sleep(for: .seconds(Self.goodbyeDuration))
            updateVisibility()
        }
    }

    /// A follow-up from the friend's bubble: Chat opens with the question typed in.
    func openChat(_ start: ChatStart) {
        pet.clearFollowUp()
        chatNavigator.pending = start
        showChatWindow()
    }

    /// A long slouch: the friend invites the user to sit up, unless it's home for a focus.
    private func postureNudge() {
        guard friend != nil, friendVisible, !pomodoro.state.friendHome else { return }
        brain.handle(.slouching)
    }

    /// Sleep, screens off or a locked screen pause the timelapse (that time is skipped in the video) and the
    /// posture check.
    private func observeSleep() {
        guard sleepObservers.isEmpty else { return }
        let workspace = NSWorkspace.shared.notificationCenter
        let distributed = DistributedNotificationCenter.default()
        let away: [(NotificationCenter, Notification.Name, Bool)] = [
            (workspace, NSWorkspace.willSleepNotification, true), (workspace, NSWorkspace.didWakeNotification, false),
            (workspace, NSWorkspace.screensDidSleepNotification, true), (workspace, NSWorkspace.screensDidWakeNotification, false),
            (distributed, Notification.Name("com.apple.screenIsLocked"), true),
            (distributed, Notification.Name("com.apple.screenIsUnlocked"), false),
        ]
        sleepObservers = away.map { center, name, isAway in
            center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.timelapse.setAway(isAway)
                    self?.posture.setAway(isAway)
                }
            }
        }
    }

    /// "Go Home": in it goes, and it stays in (quietly) until "Come Out" or a focus ends.
    func sendHome() {
        sentHome = true
        heldReaction = nil
        updateVisibility()
    }

    /// "Come Out": out of being sent home, and out of a focus that's keeping it home.
    func letOut() {
        sentHome = false
        if pomodoro.state.friendHome { pomodoro.letFriendOut() } // that change updates visibility too
        updateVisibility()
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
        let show = PresenceVisibility.friendShows(
            presenceShows: PresenceVisibility.macShowsFriend(
                isActive: presence.isActive,
                owner: presence.owner,
                socketConnected: presence.isConnected,
                phoneClaimedNearby: phoneClaimedNearby
            ),
            focusHome: pomodoro.state.friendHome,
            inGoodbye: Date.now < goodbyeUntil,
            sentHome: sentHome
        )
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
        } catch APIError.server(_, "GENERATION_FAILED", _) {
            let alert = NSAlert()
            alert.messageText = "Couldn't switch skins"
            alert.informativeText = "Your friend's lines for that skin didn't come out right. Pick it again to try again."
            alert.runModal()
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

    /// Syncs chats now and every minute; picks up a key the iPhone sealed while pairing this Mac.
    private func startChatSync(userID: String) {
        guard chatSync == nil else { return }
        let sync = ChatSync(library: chat, api: api, userID: userID,
                            folder: URL.applicationSupportDirectory.appending(path: "Chat", directoryHint: .isDirectory))
        chatSync = sync
        if let pairingInvitation { sync.resume(pairingInvitation.invitation, party: pairingInvitation.party) }
        pairingInvitation = nil
        sync.start()
        chatSyncLoop = Task { [weak sync] in
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.chatSyncInterval)
                sync?.sync()
            }
        }
    }

    private func signedOut() {
        chatSyncLoop?.cancel()
        chatSyncLoop = nil
        chatSync?.stop()
        chatSync = nil
        chat.wipe() // the account's chats stay on the server, encrypted, for the next sign-in
        timelapse.setSignedIn(false) // the camera never outlives the account
        posture.setOn(false)
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
