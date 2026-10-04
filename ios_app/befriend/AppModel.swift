//
//  AppModel.swift
//  befriend
//

import Foundation
import Observation
import PetCore
import SwiftUI
import WidgetKit
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
        /// `failure` is nil while the personality is being written, else why the last try failed.
        case hatching(name: String, failure: String?)
        case ready(FriendProfile)
    }

    private(set) var phase: Phase = .launching
    var errorMessage: String?
    /// A Mac pairing code from a scanned QR, shown once the friend is ready.
    var pendingPairingCode: String?
    /// A chat topic the widget was tapped on (M19): Home asks new chat or continue.
    var pendingFollowUp: ChatFollowUp?
    /// Chat sync (M23), once the account is known.
    private(set) var chatSync: ChatSync?
    /// A scanned Mac code asking for the chat key: Home asks before anything is sent.
    var pendingChatInvitation: ChatCrypto.Invitation?
    /// The chat-key invitation in a sign-in pairing code: accepted once the user pairs that Mac.
    @ObservationIgnored var pairingChatInvitation: ChatCrypto.Invitation?
    /// Opens Chat where a follow-up points.
    let chatNavigator = ChatNavigator()
    /// Away at least this long, the friend greets the user with a recent chat instead.
    private static let topicAfterAway: TimeInterval = 30 * 60
    let pet = PetStateMachine()
    /// The account's skin, shared with the widget through the App Group.
    let skins = SkinStore(root: SharedStore.skinsRoot)
    /// This iPhone's own pomodoro; during focus the friend studies alongside instead of talking.
    let pomodoro = PomodoroRunner(saved: SharedStore.loadPomodoro(), save: SharedStore.savePomodoro)
    /// Records each focus phase as a 1-minute timelapse when the pomodoro's setting is on (M11). The camera only
    /// runs while the app is on screen; time away is skipped.
    @ObservationIgnored private(set) lazy var timelapse = TimelapseController(
        library: TimelapseLibrary(folder: URL.documentsDirectory.appending(path: "Timelapses", directoryHint: .isDirectory)),
        skin: { [weak self] in self?.skins.current }
    )

    /// Local chat about the user's files (M18); only on this device.
    @ObservationIgnored private(set) lazy var chat = ChatLibrary()

    /// Green/red posture light (M14): shares the timelapse camera, only while the app is on screen.
    @ObservationIgnored private(set) lazy var posture: PostureChecker = {
        let checker = PostureChecker(camera: timelapse.recorder.camera)
        checker.onNudge = { [weak self] in self?.postureNudge() }
        return checker
    }()

    @ObservationIgnored let api = AppConfig.makeAPIClient()
    /// Paid skins; a purchase unlocks the skin for the account on every device.
    @ObservationIgnored private(set) lazy var shop: SkinShop = {
        let shop = SkinShop(api: api)
        shop.onUnlocked = { [weak self] in
            guard let self else { return }
            Task { await self.skins.sync(api: self.api) }
        }
        return shop
    }()
    @ObservationIgnored private var brain = PetBrain()
    @ObservationIgnored private var writingEncouragements = false
    @ObservationIgnored private var surfaces: SurfaceController!
    @ObservationIgnored private var uploader: TriggerLogUploader!
    /// The hatch request, or the wait for one already running on the server.
    @ObservationIgnored private var hatchTask: Task<Void, Never>?
    @ObservationIgnored private var backgroundedAt: Date?
    @ObservationIgnored private var isForeground = false
    @ObservationIgnored private var presenceClaim: Task<Void, Never>?
    @ObservationIgnored private var peer: PresencePeer?

    init() {
        surfaces = SurfaceController(api: api)
        let queueURL = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: AppConfig.appGroup)
            ?? URL.applicationSupportDirectory
        uploader = TriggerLogUploader(api: api, fileURL: queueURL.appending(path: "trigger-queue.json"))
        PokeIntent.handler = { [weak self] in await self?.poke() }
        skins.onChange = { [weak self] in
            guard let self else { return }
            self.surfaces.skinChanged()
            // A switch that landed comes with lines written for it; a reset while signing out doesn't.
            guard self.api.isSignedIn, self.friend != nil else { return }
            Task { await self.refresh() }
        }
        PomodoroIntent.handler = { [weak self] in self?.pomodoroCommand($0) }
        shop.start()
        pomodoro.onFocusEnded = { PhonePomodoro.chime($0) }
        pomodoro.onChange = { [weak self] in self?.pomodoroChanged() }
        timelapse.recorder.onStateChange = { [weak self] in self?.timelapseChanged() }
        // Focusing together is quiet; otherwise the friend reacts (a break, being let out).
        pomodoro.onMoment = { [weak self] moment in
            guard let self, !self.pomodoro.state.friendHome, self.friend != nil else { return }
            self.brain.handle(.pomodoro(moment))
        }
        pomodoroChanged()
        _ = posture // turns itself back on if it was on
    }

    /// A long slouch: the friend invites the user to sit up, unless it's focusing alongside them.
    private func postureNudge() {
        guard friend != nil, !pomodoro.state.friendHome else { return }
        brain.handle(.slouching)
    }

    // MARK: Pomodoro

    /// A Live Activity button: start (also resumes), pause or stop. A focus that ended meanwhile settles first.
    func pomodoroCommand(_ command: String) {
        pomodoro.settle()
        switch command {
        case "start": pomodoro.start()
        case "pause": pomodoro.pause()
        case "stop": pomodoro.stop()
        default: break
        }
    }

    private func pomodoroChanged() {
        PhonePomodoro.schedule(pomodoro.state)
        timelapse.sync(pomodoro.state)
        timelapseChanged()
    }

    /// The Live Activity says whether this focus is being recorded, or paused while the app is away.
    private func timelapseChanged() {
        let status: PomodoroSurface.TimelapseStatus? = switch timelapse.recorder.state {
        case .idle: nil
        case .recording: .recording
        case .paused: .paused
        }
        surfaces.pomodoroChanged(PomodoroSurface(pomodoro.state, at: .now, timelapse: status))
        UIApplication.shared.isIdleTimerDisabled = status == .recording // the camera needs the screen on
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
                if latest.isReady { adopt(latest) } else { resumeHatching(latest) }
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
            await skins.sync(api: api)
        } catch {
            errorMessage = Self.message(for: error)
        }
    }

    func completeOnboarding(_ payload: CompleteOnboarding) async throws {
        let created = try await api.completeOnboarding(payload)
        await skins.sync(api: api) // the picked look shows while it hatches
        if created.isReady { adopt(created) } else { resumeHatching(created) }
    }

    func signOut() async {
        await api.logout()
        signedOut()
    }

    func deleteAccount() async throws {
        try await api.deleteAccount()
        signedOut()
    }

    /// SettingsView changed the sync settings on the server; record accordingly from now on.
    func syncSettingsChanged(_ settings: SyncSettings) {
        uploader.settings = settings
    }

    private func startChatSync(userID: String) {
        guard chatSync == nil else { return }
        let sync = ChatSync(library: chat, api: api, userID: userID,
                            folder: URL.applicationSupportDirectory.appending(path: "Chat", directoryHint: .isDirectory))
        chatSync = sync
        sync.start()
    }

    /// Sends the chat key to the Mac that showed the code (after the user said yes), or receives it from there.
    func acceptChatInvitation(_ invitation: ChatCrypto.Invitation) {
        pendingChatInvitation = nil
        chatSync?.accept(invitation)
    }

    private func signedOut() {
        chatSync?.stop()
        chatSync = nil
        chat.wipe() // the account's chats stay on the server, encrypted, for the next sign-in
        timelapse.setSignedIn(false) // the camera never outlives the account
        posture.setOn(false)
        uploader.stop()
        uploader.clear()
        hatchTask?.cancel()
        hatchTask = nil
        presenceClaim?.cancel()
        presenceClaim = nil
        peer?.stop()
        peer = nil
        SharedStore.saveFriend(nil)
        SharedStore.saveEncouragements(nil)
        surfaces.signedOut()
        skins.reset()
        brain = PetBrain()
        phase = .signedOut
    }

    /// Opens Chat with a follow-up typed in; the bubble that offered it goes.
    func openChat(_ start: ChatStart) {
        pet.clearFollowUp()
        pendingFollowUp = nil
        chatNavigator.pending = start
    }

    func handleDeepLink(_ url: URL) {
        if let followUp = ChatFollowUp(url: url) { return pendingFollowUp = followUp }
        if url.scheme == "befriend", url.host() == "chatsync" { return pendingChatInvitation = ChatCrypto.Invitation(url: url) }
        if url.host() == "pair" { pairingChatInvitation = ChatCrypto.Invitation(url: url) }
        guard url.scheme == "befriend", url.host() == "pair",
              let code = URLComponents(url: url, resolvingAgainstBaseURL: false)?
                .queryItems?.first(where: { $0.name == "code" })?.value,
              !code.isEmpty else { return }
        pendingPairingCode = code
    }

    // MARK: Friend

    private func adopt(_ latest: FriendProfile) {
        hatchTask?.cancel()
        hatchTask = nil
        let isNewVersion = friend?.personality.version != latest.personality.version
        SharedStore.saveFriend(latest)
        phase = .ready(latest)
        if isNewVersion {
            timelapse.setSignedIn(true)
            brain = PetBrain(friend: latest)
            brain.onReaction = { [weak self] in self?.show($0) }
            brain.context = { [pomodoro] in pomodoro.state.promptContext(at: .now) }
            brain.skin = { [skins] in skins.current?.vocabulary ?? (PetAction.builtIn, PetMood.builtIn) }
            brain.chatExchanges = { [weak self] in self?.chat.recentExchanges() ?? [] }
            timelapse.title = { [weak self] context in await self?.brain.timelapseTitle(for: context) }
            let hello = brain.quickReaction(to: .returned(afterSeconds: 0))
            show(hello)
            SharedStore.saveEncouragements(nil) // the old personality's lines
            Task { await refillEncouragements() }
            surfaces.friendReady(latest, state: FriendSurfaceState(presence: .here, mood: hello.mood, action: hello.action, line: hello.dialogue))
        }
        if peer == nil {
            Task { [weak self] in
                guard let self, self.peer == nil, let me = try? await self.api.me() else { return }
                self.startChatSync(userID: me.id)
                self.peer = PresencePeer(userID: me.id, displayName: UIDevice.current.name)
                if self.isForeground { self.startClaiming() }
            }
        }
        if isForeground { startClaiming() }
    }

    // MARK: Presence

    /// While the app is open the friend is on the iPhone: claim it now and every minute (a claim lasts 5), and tell
    /// a Mac on the same Wi-Fi directly.
    private func startClaiming() {
        peer?.start()
        peer?.send(.claim)
        uploader.start()
        Task { [weak self] in
            guard let self, let settings = try? await self.api.syncSettings() else { return }
            self.uploader.settings = settings
        }
        guard presenceClaim == nil else { return }
        presenceClaim = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                _ = try? await self.api.claimPresence()
                self.peer?.send(.claim)
                try? await Task.sleep(for: .seconds(60))
            }
        }
    }

    /// Leaving the app hands the friend back (to an active Mac) and uploads queued activity, in the background.
    private func stopClaiming() {
        presenceClaim?.cancel()
        presenceClaim = nil
        peer?.send(.release)
        uploader.stop()
        let app = UIApplication.shared
        var taskID = UIBackgroundTaskIdentifier.invalid
        taskID = app.beginBackgroundTask(withName: "presence-release") {
            app.endBackgroundTask(taskID)
        }
        Task { [weak self] in
            _ = try? await self?.api.releasePresence()
            await self?.uploader.flush()
            self?.peer?.stop()
            app.endBackgroundTask(taskID)
        }
    }

    /// Picks up a friend that hasn't hatched: one never tried hatches now, one being written is waited for, and
    /// one that failed waits for Try again. A hatch already under way here is left alone.
    private func resumeHatching(_ friend: FriendProfile) {
        guard hatchTask == nil else { return }
        if friend.hatchFailed {
            phase = .hatching(name: friend.name, failure: Self.hatchFailed(friend.name))
        } else {
            startHatchTask(name: friend.name, request: !friend.isBeingWritten)
        }
    }

    /// Try again on the hatching screen.
    func retryHatch() {
        guard case .hatching(let name, _) = phase, hatchTask == nil else { return }
        startHatchTask(name: name, request: true)
    }

    private func startHatchTask(name: String, request: Bool) {
        phase = .hatching(name: name, failure: nil)
        hatchTask = Task { [weak self] in
            await self?.hatch(name: name, request: request)
            self?.hatchTask = nil
        }
    }

    /// Asks the server to write the personality (or, with `request` false, waits for the write already running).
    /// A dropped connection doesn't mean the write failed, so any error is checked against the server first.
    private func hatch(name: String, request: Bool) async {
        var failure = Self.hatchFailed(name)
        if request {
            do {
                return adopt(try await api.hatch())
            } catch APIError.signedOut {
                return signedOut()
            } catch APIError.server(_, "GENERATION_RUNNING", _) {
                // another request is writing it: wait for that one below
            } catch APIError.server(_, "GENERATION_FAILED", _) {
                // the model's words didn't pass: the default failure
            } catch {
                failure = Self.message(for: error) // busy, offline, …
            }
        }
        while !Task.isCancelled {
            guard let latest = try? await api.friend() else { break }
            if latest.isReady { return adopt(latest) }
            guard latest.isBeingWritten else { break }
            try? await Task.sleep(for: .seconds(3))
        }
        guard !Task.isCancelled, case .hatching = phase else { return }
        phase = .hatching(name: name, failure: failure)
    }

    private static func hatchFailed(_ name: String) -> String {
        "\(name) couldn't hatch this time. The words didn't come out right, so let's try again."
    }

    func poke() async {
        adoptSavedFriendIfNeeded() // a Dynamic Island tap can launch the app without its window
        guard friend != nil else { return }
        uploader.record(.poked)
        show(brain.quickReaction(to: .poked, mood: pet.mood))
        show(await brain.react(to: .poked))
    }

    private func show(_ reaction: PetReaction) {
        guard !pomodoro.state.friendHome else { return } // focusing together: no chatter
        pet.apply(reaction)
        guard reaction.followUp == nil else { return } // chat topics stay off the Lock Screen's Live Activity
        surfaces.update(with: reaction)
    }

    func scenePhaseChanged(_ scenePhase: ScenePhase) {
        if scenePhase == .active {
            pomodoro.settle()
            ExplainInbox.adoptAll(into: chat) // screenshots explained from the share sheet (M31)
        }
        if scenePhase != .inactive {
            timelapse.setAway(scenePhase != .active)
            posture.setAway(scenePhase != .active)
            timelapseChanged()
        }
        if scenePhase != .inactive { isForeground = scenePhase == .active }
        if scenePhase == .active, api.isSignedIn {
            Task { await skins.sync(api: api) } // a skin picked on the Mac, granted, or revoked meanwhile
            chatSync?.sync()
        }
        guard let current = friend else { return }
        switch scenePhase {
        case .active:
            let away = backgroundedAt.map { Date.now.timeIntervalSince($0) } ?? 0
            backgroundedAt = nil
            brain.handle(away >= Self.topicAfterAway ? .chatTopic : .returned(afterSeconds: away))
            uploader.record(.returned(afterSeconds: away))
            startClaiming()
            Task { await refillEncouragements() }
            Task {
                if let latest = try? await api.friend(), latest.isReady, latest.personality.version != current.personality.version {
                    adopt(latest)
                }
            }
        case .background:
            backgroundedAt = .now
            uploader.record(.leftApp)
            show(brain.quickReaction(to: .leftApp, mood: pet.mood))
            stopClaiming()
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
        uploader.record(.checkIn)
        show(await brain.react(to: .checkIn))
        await refillEncouragements()
        await uploader.flush()
        await skins.sync(api: api)
    }

    /// The widget can't run the model, so the app writes its encouraging lines ahead, one per hour, and writes a
    /// new batch when fewer than `encouragementsLow` hours are left (on open and each hourly check-in).
    private static let encouragementBatch = 6
    private static let encouragementsLow = 3

    private func refillEncouragements() async {
        let hourAgo = Date.now.addingTimeInterval(-3600).timeIntervalSince1970
        guard friend != nil, !writingEncouragements,
              SharedStore.loadEncouragements().filter({ $0.state.updatedAt > hourAgo }).count < Self.encouragementsLow else { return }
        writingEncouragements = true
        defer { writingEncouragements = false }
        let start = Date.now
        let lines = await brain.encouragements(Self.encouragementBatch).enumerated().map { hour, line in
            SharedStore.WidgetLine(state: FriendSurfaceState(presence: .here, mood: line.mood, action: line.action, line: line.dialogue,
                                                             updatedAt: start.addingTimeInterval(Double(hour) * 3600)),
                                   followUp: line.followUp)
        }
        guard friend != nil else { return } // signed out meanwhile
        SharedStore.saveEncouragements(lines)
        WidgetCenter.shared.reloadTimelines(ofKind: "FriendWidget")
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
        case APIError.server(_, "GENERATION_FAILED", _): "Your friend's words didn't come out right this time. Try again."
        case APIError.server(_, _, let message) where !message.isEmpty: message
        case is URLError: "Can't reach befriend right now. Check your connection."
        default: "Something went wrong. Please try again."
        }
    }
}
