//
//  StatusMenu.swift
//  befriend
//

import AppKit
import Observation
import PetCore

/// The menu bar item: activity sync controls, sign in/out, quit. Rebuilt each time it opens. It's also the friend's
/// home: while the friend is inside, the icon is its head in the current mood.
final class StatusMenu: NSObject, NSMenuDelegate {
    private static let iconSize = NSSize(width: 16, height: 16)

    private let controller: MacController
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)

    init(controller: MacController) {
        self.controller = controller
        super.init()
        let menu = NSMenu()
        menu.delegate = self
        item.menu = menu
        controller.walker.dockFrame = { [weak self] in self?.iconFrame }
        updateIcon()
    }

    private var iconFrame: CGRect? {
        guard let button = item.button, let window = button.window else { return nil }
        return window.convertToScreen(button.convert(button.bounds, to: nil))
    }

    /// Redraws whenever what it shows changes: the stage, whether the friend is home, its mood, or the skin.
    private func updateIcon() {
        withObservationTracking {
            item.button?.image = icon()
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
            menu.addItem(.separator())
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
            let item = NSMenuItem(title: choice.name, action: #selector(selectSkin(_:)), keyEquivalent: "").targeted(self)
            item.representedObject = choice.id
            item.state = controller.skins.current?.pickID == choice.id ? .on : .off
            submenu.addItem(item)
        }
        let item = NSMenuItem(title: "Skin", action: nil, keyEquivalent: "")
        item.submenu = submenu
        return item
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
