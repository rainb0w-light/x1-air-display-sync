import AppKit
import ServiceManagement
import SwiftUI

enum LoginItem {
    static let service = SMAppService.mainApp

    static var statusLabel: String {
        switch service.status {
        case .enabled: "已开启"
        case .notRegistered: "已关闭"
        case .requiresApproval: "需要在系统设置中批准"
        case .notFound: "系统找不到登录项"
        @unknown default: "状态未知"
        }
    }

    static func enable() throws {
        if service.status != .enabled && service.status != .requiresApproval {
            try service.register()
        }
    }

    static func disable() throws {
        if service.status == .enabled || service.status == .requiresApproval {
            try service.unregister()
        }
    }

    static func toggle() throws {
        if service.status == .enabled || service.status == .requiresApproval {
            try disable()
        } else {
            try enable()
        }
    }
}

@MainActor
final class DisplaySyncAppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate, NSWindowDelegate {
    private var statusItem: NSStatusItem?
    private var panel: NSWindow?
    private let restoreItem = NSMenuItem(title: "恢复右屏扩展…", action: #selector(restoreExtension), keyEquivalent: "")
    private var recoveryTarget: DisplayRecovery.Target?
    private var restoringExtension = false
    private let loginItem = NSMenuItem(title: "登录时启动", action: #selector(toggleLoginItem), keyEquivalent: "")
    private let approvalItem = NSMenuItem(title: "打开系统登录项设置…", action: #selector(openLoginSettings), keyEquivalent: "")
    private let showOnLaunch: Bool

    init(showOnLaunch: Bool) {
        self.showOnLaunch = showOnLaunch
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        let image = Bundle.main.url(forResource: "MenuBar", withExtension: "png").flatMap(NSImage.init(contentsOf:))
            ?? NSImage(systemSymbolName: "display.2", accessibilityDescription: "X1 Air 双屏调节")
        image?.isTemplate = true
        image?.size = NSSize(width: 18, height: 18)
        item.button?.image = image
        item.button?.setAccessibilityLabel("X1 Air 双屏调节")
        item.button?.toolTip = "X1 Air 双屏调节"

        let menu = NSMenu(title: "X1 Air 双屏调节")
        menu.delegate = self
        menu.addItem(menuItem("打开双屏调节…", action: #selector(showPanel)))
        restoreItem.target = self
        restoreItem.isHidden = true
        menu.addItem(restoreItem)
        menu.addItem(.separator())
        loginItem.target = self
        approvalItem.target = self
        menu.addItem(loginItem)
        menu.addItem(approvalItem)
        menu.addItem(.separator())
        menu.addItem(menuItem("退出", action: #selector(quit), key: "q"))
        updateLoginMenu()
        item.menu = menu
        statusItem = item
        DisplayRecovery.rememberDesktopModes()
        if showOnLaunch { showPanel() }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showPanel()
        return true
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        updateLoginMenu()
        recoveryTarget = restoringExtension ? nil : DisplayRecovery.target()
        restoreItem.isHidden = recoveryTarget == nil
    }

    func applicationDidChangeScreenParameters(_ notification: Notification) {
        if !restoringExtension { DisplayRecovery.rememberDesktopModes() }
    }

    func windowWillClose(_ notification: Notification) {
        if notification.object as? NSWindow === panel {
            panel = nil
        }
    }

    private func menuItem(_ title: String, action: Selector, key: String = "") -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self
        return item
    }

    private func updateLoginMenu() {
        let status = LoginItem.service.status
        loginItem.state = status == .enabled ? .on : status == .requiresApproval ? .mixed : .off
        loginItem.toolTip = LoginItem.statusLabel
        approvalItem.isHidden = status != .requiresApproval
    }

    @objc private func showPanel() {
        if panel == nil {
            let hosting = NSHostingController(rootView: BrightnessView())
            hosting.sizingOptions = [.intrinsicContentSize, .preferredContentSize]
            let window = NSWindow(contentViewController: hosting)
            window.title = "右屏画面调节"
            window.styleMask = [.titled, .closable, .miniaturizable]
            window.isReleasedWhenClosed = false
            window.delegate = self
            window.center()
            panel = window
        }

        NSApp.activate()
        panel?.makeKeyAndOrderFront(nil)
    }

    @objc private func restoreExtension() {
        guard !restoringExtension, let recoveryTarget else { return }
        restoringExtension = true
        restoreItem.isHidden = true

        Task {
            let alert = NSAlert()
            do {
                let scaleRestored = try await DisplayRecovery.restore(recoveryTarget)
                alert.messageText = "右屏已恢复为扩展显示器"
                if !scaleRestored {
                    alert.informativeText = "上次使用的缩放未能恢复。可以在「系统设置 → 显示器」中重新选择。"
                }
                DisplayRecovery.rememberDesktopModes()
            } catch {
                alert.alertStyle = .warning
                alert.messageText = "无法确认右屏恢复"
                alert.informativeText = error.localizedDescription
            }
            restoringExtension = false
            NSApp.activate()
            alert.runModal()
        }
    }

    @objc private func toggleLoginItem() {
        do {
            try LoginItem.toggle()
        } catch {
            NSApp.activate()
            let alert = NSAlert(error: error)
            alert.messageText = "无法更改登录时启动"
            alert.runModal()
        }
        updateLoginMenu()
    }

    @objc private func openLoginSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}
