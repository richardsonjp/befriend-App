//
//  StatusMenu.swift
//  befriend
//

import AppKit
import Observation
import PetCore
import StoreKit
import SwiftUI

/// The menu bar item. It's the friend's home: while the friend is inside, the icon is its head in the current mood,
/// with the pomodoro's countdown beside it while one runs. A click opens the pomodoro popover once the friend is
/// ready; right-click, "…" in the popover, or any click before then opens the menu (activity sync controls, skin,
/// sign in/out, quit), rebuilt each time it opens.
final class StatusMenu: NSObject, NSMenuDelegate {
    private static let iconSize = NSSize(width: 16, height: 16)

    private let controller: MacController
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let menu = NSMenu()
    private let popover = NSPopover()
    private var timelapsesWindow: NSWindow?
    private var calibrationWindow: NSWindow?
    private var framingWindow: NSWindow?
    private var chatWindow: NSWindow?

    init(controller: MacController) {
        self.controller = controller
        super.init()
        menu.delegate = self
        popover.behavior = .transient
        popover.contentViewController = NSHostingController(rootView: VStack(alignment: .leading, spacing: 16) {
            PomodoroControls(
                pomodoro: controller.pomodoro,
                timelapse: controller.timelapse,
                preview: true,
                openTimelapses: { [weak self] in self?.showTimelapses() },
                openFraming: { [weak self] in self?.showFraming() },
                more: { [weak self] in self?.showMenu() }
            )
            Divider()
            PostureControls(checker: controller.posture) { [weak self] turnOn in self?.showCalibration(turnOnAfter: turnOn) }
            Divider()
            Button { [weak self] in self?.showChat() } label: {
                Label("Chat About Your Files", systemImage: "bubble.left.and.text.bubble.right").frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.plain)
        }.padding(16).frame(width: 290))
        if let button = item.button {
            button.target = self
            button.action = #selector(clicked)
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
            button.imagePosition = .imageLeading
            button.font = .monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        }
        controller.walker.dockFrame = { [weak self] in self?.iconFrame }
        controller.showChatWindow = { [weak self] in self?.showChat() }
        updateIcon()
    }

    @objc private func clicked() {
        guard controller.stage == .ready, NSApp.currentEvent?.type != .rightMouseUp else { return showMenu() }
        if popover.isShown {
            popover.performClose(nil)
        } else if let button = item.button {
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            NSApp.activate() // so the popover takes keyboard focus and closes on an outside click
        }
    }

    /// The saved timelapses in their own window (M13), reused while it's open.
    private func showTimelapses() {
        popover.performClose(nil)
        if timelapsesWindow == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 540, height: 620),
                                  styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
            window.title = "Timelapses"
            window.isReleasedWhenClosed = false
            window.contentView = NSHostingView(rootView: TimelapseGallery(
                library: controller.timelapse.library,
                reveal: { NSWorkspace.shared.activateFileViewerSelecting([$0]) }
            ))
            window.center()
            timelapsesWindow = window
        }
        NSApp.activate()
        timelapsesWindow?.makeKeyAndOrderFront(nil)
    }

    /// Chat about the user's files (M18) in its own window, reused while it's open.
    @objc private func showChat() {
        popover.performClose(nil)
        if chatWindow == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 860, height: 620),
                                  styleMask: [.titled, .closable, .resizable, .miniaturizable, .fullSizeContentView],
                                  backing: .buffered, defer: false)
            window.title = "Chat"
            window.isReleasedWhenClosed = false
            window.contentView = NSHostingView(rootView: MacChatRoot(controller: controller))
            window.center()
            window.setFrameAutosaveName("Chat")
            chatWindow = window
        }
        NSApp.activate()
        chatWindow?.makeKeyAndOrderFront(nil)
    }

    /// Posture calibration in its own window: a transient popover can't host a sheet.
    private func showCalibration(turnOnAfter: Bool) {
        popover.performClose(nil)
        calibrationWindow?.close()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 420, height: 520),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "Posture"
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: PostureCalibrationView(
            checker: controller.posture, turnOnAfter: turnOnAfter,
            finish: { [weak window] in window?.close() }
        ))
        window.center()
        calibrationWindow = window
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
    }

    /// The timelapse's format and framing in its own window, like posture calibration.
    private func showFraming() {
        popover.performClose(nil)
        framingWindow?.close()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 600),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "Video Format"
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: TimelapseFramingView(
            pomodoro: controller.pomodoro, camera: controller.timelapse.recorder.camera,
            recording: controller.timelapse.isRecording, finish: { [weak window] in window?.close() }
        ))
        window.center()
        framingWindow = window
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
    }

    @objc private func recalibratePosture() {
        showCalibration(turnOnAfter: false)
    }

    /// Opens the menu under the icon: attached only while it's open, so a normal click reaches `clicked`.
    private func showMenu() {
        popover.performClose(nil)
        item.menu = menu
        item.button?.performClick(nil)
        item.menu = nil
    }

    private var iconFrame: CGRect? {
        guard let button = item.button, let window = button.window else { return nil }
        return window.convertToScreen(button.convert(button.bounds, to: nil))
    }

    /// Redraws whenever what it shows changes: the stage, whether the friend is home, its mood, the skin, or the
    /// pomodoro's countdown.
    private func updateIcon() {
        withObservationTracking {
            item.button?.image = icon()
            item.button?.attributedTitle = countdown()
        } onChange: { [weak self] in
            Task { @MainActor in self?.updateIcon() }
        }
    }

    private func icon() -> NSImage? {
        let outline = NSImage(systemSymbolName: "cat", accessibilityDescription: "befriend")
        guard controller.stage == .ready, controller.walker.isInside, let skin = controller.skins.current,
              let head = NSImage(contentsOf: skin.mini(controller.pet.mood)) else { return outline }
        // The 16-pixel head at 16 points, pixels kept square.
        let image = NSImage(size: Self.iconSize, flipped: false) { rect in
            NSGraphicsContext.current?.imageInterpolation = .none
            head.draw(in: rect)
            return true
        }
        image.accessibilityDescription = "befriend, your friend is here"
        return image
    }

    /// The posture light while the check is on (a green or red figure; gray when it can't see you), then " 18:42"
    /// while a focus runs or is paused, with a red " ●" first while a timelapse records.
    private func countdown() -> NSAttributedString {
        let pomodoro = controller.pomodoro
        guard controller.stage == .ready else { return NSAttributedString() }
        let font = NSFont.monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        let title = NSMutableAttributedString()
        let posture = controller.posture.status
        if posture != .off, let figure = NSImage(systemSymbolName: "figure.stand", accessibilityDescription: "Posture: \(posture.title)")?
            .withSymbolConfiguration(.init(paletteColors: [NSColor(posture.color)])) {
            let attachment = NSTextAttachment()
            attachment.image = figure
            title.append(NSAttributedString(string: " "))
            title.append(NSAttributedString(attachment: attachment))
        }
        guard pomodoro.state.status != .ready else { return title }
        if controller.timelapse.recorder.state == .recording {
            title.append(NSAttributedString(string: " ●", attributes: [.foregroundColor: NSColor.systemRed, .font: font]))
        }
        title.append(NSAttributedString(string: " " + Pomodoro.clock(pomodoro.state.remaining(at: pomodoro.now)), attributes: [.font: font]))
        return title
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        switch controller.stage {
        case .ready:
            let pause = NSMenuItem(title: "Pause Activity Sync", action: #selector(togglePause), keyEquivalent: "")
            pause.state = controller.settings.logSyncPaused ? .on : .off
            menu.addItem(pause.targeted(self))

            let appName = controller.frontmostApp
            let stop = NSMenuItem(title: appName.map { "Stop Tracking “\($0)”" } ?? "Stop Tracking an App", action: appName == nil ? nil : #selector(stopTracking), keyEquivalent: "")
            menu.addItem(stop.targeted(self))
            menu.addItem(NSMenuItem(title: "Delete Synced Activity…", action: #selector(deleteActivity), keyEquivalent: "").targeted(self))
            if controller.posture.baseline != nil {
                menu.addItem(NSMenuItem(title: "Re-calibrate Posture…", action: #selector(recalibratePosture), keyEquivalent: "").targeted(self))
            }
            menu.addItem(.separator())
            menu.addItem(NSMenuItem(title: "Chat…", action: #selector(showChat), keyEquivalent: "").targeted(self))
            menu.addItem(skinMenu())
            #if DEBUG
            if controller.walker.isInside {
                menu.addItem(NSMenuItem(title: "Come Out", action: #selector(comeOut), keyEquivalent: "").targeted(self))
            }
            #endif
            menu.addItem(.separator())
            menu.addItem(NSMenuItem(title: "Sign Out", action: #selector(signOut), keyEquivalent: "").targeted(self))
        case .waitingForFriend:
            menu.addItem(NSMenuItem(title: "Show Setup…", action: #selector(showWindow), keyEquivalent: "").targeted(self))
            menu.addItem(NSMenuItem(title: "Sign Out", action: #selector(signOut), keyEquivalent: "").targeted(self))
        case .signedOut, .launching:
            menu.addItem(NSMenuItem(title: "Sign In…", action: #selector(showWindow), keyEquivalent: "").targeted(self))
        }
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit befriend", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
    }

    /// The built-in skin plus the skins the account was granted; the account's pick is checked.
    private func skinMenu() -> NSMenuItem {
        let submenu = NSMenu()
        let choices: [(name: String, id: String?)] = [("Pixel Cat", nil)] + controller.skins.granted.map { ($0.name, $0.id) }
        for choice in choices {
            let dressing = controller.skins.pending.map { $0.skinId == choice.id } ?? false
            let title = dressing ? "\(choice.name) (getting dressed…)" : choice.name
            let item = NSMenuItem(title: title, action: #selector(selectSkin(_:)), keyEquivalent: "").targeted(self)
            item.representedObject = choice.id
            item.state = controller.skins.current?.pickID == choice.id ? .on : .off
            submenu.addItem(item)
        }
        let forSale = controller.shop.items.filter { !$0.skin.owned && $0.product != nil }
        if !forSale.isEmpty {
            submenu.addItem(.separator())
            for shopItem in forSale {
                let price = shopItem.product?.displayPrice ?? ""
                let buy = NSMenuItem(title: "Buy \(shopItem.skin.name) — \(price)", action: #selector(buySkin(_:)), keyEquivalent: "").targeted(self)
                buy.representedObject = shopItem.id
                buy.isEnabled = controller.shop.busy == nil
                submenu.addItem(buy)
            }
        }
        submenu.addItem(.separator())
        submenu.addItem(NSMenuItem(title: "Restore Purchases", action: #selector(restorePurchases), keyEquivalent: "").targeted(self))
        let item = NSMenuItem(title: "Skin", action: nil, keyEquivalent: "")
        item.submenu = submenu
        return item
    }

    @objc private func buySkin(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String,
              let shopItem = controller.shop.items.first(where: { $0.id == id }) else { return }
        Task { await controller.shop.buy(shopItem) }
    }

    @objc private func restorePurchases() {
        Task { await controller.shop.restore() }
    }

    @objc private func selectSkin(_ sender: NSMenuItem) {
        let id = sender.representedObject as? String
        Task { await controller.selectSkin(id) }
    }

    @objc private func comeOut() {
        controller.walker.comeOut()
    }

    @objc private func togglePause() {
        Task { await controller.togglePause() }
    }

    @objc private func stopTracking() {
        Task { await controller.stopTrackingFrontmostApp() }
    }

    @objc private func deleteActivity() {
        let alert = NSAlert()
        alert.messageText = "Delete your synced activity?"
        alert.informativeText = "The app switches and away times befriend has synced are deleted from our server. Your friend stays."
        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Cancel")
        alert.buttons.first?.hasDestructiveAction = true
        NSApp.activate()
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        Task { await controller.deleteActivity() }
    }

    @objc private func signOut() {
        Task { await controller.signOut() }
    }

    @objc private func showWindow() {
        controller.reopenWindow()
    }
}

private extension NSMenuItem {
    func targeted(_ target: AnyObject) -> NSMenuItem {
        self.target = target
        return self
    }
}

/// Chat in its window, following the controller: sync appears once the account is known.
private struct MacChatRoot: View {
    let controller: MacController

    var body: some View {
        ChatRoot(library: controller.chat, friend: controller.friend, navigator: controller.chatNavigator, sync: controller.chatSync)
    }
}
