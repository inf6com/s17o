import Cocoa
import Combine
import SwiftUI

@main
enum S17oMain {
    private static let appDelegate = AppDelegate()

    static func main() {
        let application = NSApplication.shared
        application.delegate = appDelegate
        _ = NSApplicationMain(CommandLine.argc, CommandLine.unsafeArgv)
    }
}

private enum DockEdge {
    case bottom, left, right

    static func detect(for screen: NSScreen) -> DockEdge {
        let f = screen.frame
        let v = screen.visibleFrame
        let left   = v.minX - f.minX
        let right  = f.maxX - v.maxX
        let bottom = v.minY - f.minY
        if left > right, left > bottom { return .left }
        if right > left, right > bottom { return .right }
        return .bottom
    }
}

private final class DockPopupPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let model = AppModel()
    private let popupSize = NSSize(width: 488, height: 668)
    private var panel: DockPopupPanel?
    private var setupObserver: AnyCancellable?
    private var detectionObserver: AnyCancellable?

    func applicationWillFinishLaunching(_ notification: Notification) {
        NSApp.mainMenu = buildMainMenu()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        if model.isSetupComplete {
            configureMonitoringPanel()
            observeKeywordDetection()
            // 起動直後はマウスが Dock アイコン上にあるため anchorAtMouse: true でアイコン中央付近に表示
            showPanel(anchorAtMouse: true)
        } else {
            showOnboardingWindow()
            observeSetupCompletion()
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationWillTerminate(_ notification: Notification) {
        Task { await model.stopMonitoring() }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        // 表示中なら非表示に、非表示なら Dock アイコン位置に表示（トグル）
        if let p = panel, p.isVisible {
            p.orderOut(nil)
        } else {
            showPanel(anchorAtMouse: true)
        }
        return true
    }

    func applicationDidChangeScreenParameters(_ notification: Notification) {
        if let p = panel, p.isVisible { positionPanel(p) }
    }

    func application(_ application: NSApplication, shouldSaveApplicationState coder: NSCoder) -> Bool { false }
    func application(_ application: NSApplication, shouldRestoreApplicationState coder: NSCoder) -> Bool { false }
    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool { false }

    // MARK: - Panel

    private func observeKeywordDetection() {
        detectionObserver = model.$latestDetection
            .compactMap { $0 }
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                guard let self, let p = self.panel else { return }
                if !p.isVisible {
                    self.showPanel()
                } else {
                    p.makeKeyAndOrderFront(nil)
                    NSApp.activate(ignoringOtherApps: true)
                }
            }
    }

    private func configureMonitoringPanel() {
        guard panel == nil else { return }
        let rootView = MonitoringView(model: model)
        let controller = NSHostingController(rootView: rootView)
        let p = DockPopupPanel(
            contentRect: NSRect(origin: .zero, size: popupSize),
            styleMask: [.borderless, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        p.contentViewController = controller
        p.isReleasedWhenClosed = false
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = false          // MonitoringView 側で shadow を持つ
        p.hidesOnDeactivate = false
        p.level = .floating
        p.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        panel = p
    }

    private func showPanel(anchorAtMouse: Bool = false) {
        guard let p = panel else { return }
        NSApp.activate(ignoringOtherApps: true)
        positionPanel(p, anchorAtMouse: anchorAtMouse)
        p.makeKeyAndOrderFront(nil)
    }

    private func positionPanel(_ p: NSPanel, anchorAtMouse: Bool = false) {
        guard let screen = anchorAtMouse ? pointerScreen() : NSScreen.main ?? NSScreen.screens.first else { return }
        let v      = screen.visibleFrame
        let mouse  = NSEvent.mouseLocation
        let margin: CGFloat = 12
        let pad:    CGFloat = 16
        let w = popupSize.width
        let h = popupSize.height

        let xRange = (v.minX + pad)...(v.maxX - w - pad)
        let yRange = (v.minY + pad)...(v.maxY - h - pad)

        // anchorAtMouse=true: Dock アイコンクリック時、マウスは必ずアイコン上にある
        // anchorAtMouse=false: 初回起動など、スクリーン中央を使う
        let anchorX = anchorAtMouse ? mouse.x : v.midX
        let anchorY = anchorAtMouse ? mouse.y : v.midY

        let origin: NSPoint
        switch DockEdge.detect(for: screen) {
        case .bottom:
            origin = NSPoint(
                x: clamp(anchorX - w / 2, within: xRange),
                y: v.minY + margin
            )
        case .left:
            origin = NSPoint(
                x: v.minX + margin,
                y: clamp(anchorY - h / 2, within: yRange)
            )
        case .right:
            origin = NSPoint(
                x: v.maxX - w - margin,
                y: clamp(anchorY - h / 2, within: yRange)
            )
        }
        p.setFrame(NSRect(origin: origin, size: popupSize), display: false)
    }

    private func pointerScreen() -> NSScreen? {
        let pt = NSEvent.mouseLocation
        return NSScreen.screens.first { NSMouseInRect(pt, $0.frame, false) }
            ?? NSScreen.main
            ?? NSScreen.screens.first
    }

    private func clamp(_ v: CGFloat, within r: ClosedRange<CGFloat>) -> CGFloat {
        min(max(v, r.lowerBound), r.upperBound)
    }

    // MARK: - Onboarding

    private var onboardingWindow: NSWindow?

    private func showOnboardingWindow() {
        let rootView = OnboardingView(model: model)
        let controller = NSHostingController(rootView: rootView)
        let w = NSWindow(contentViewController: controller)
        w.title = "s17o"
        w.setContentSize(NSSize(width: 520, height: 460))
        w.styleMask = [.titled]
        w.isReleasedWhenClosed = false
        w.collectionBehavior = [.fullScreenNone]
        w.center()
        w.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        onboardingWindow = w
    }

    private func observeSetupCompletion() {
        setupObserver = model.$isSetupComplete
            .dropFirst()
            .filter { $0 }
            .first()
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                guard let self else { return }
                self.onboardingWindow?.close()
                self.configureMonitoringPanel()
                self.observeKeywordDetection()
                self.showPanel()
            }
    }

    // MARK: - Menu

    private func buildMainMenu() -> NSMenu {
        let mainMenu = NSMenu(title: "Main Menu")
        mainMenu.addItem(buildApplicationMenuItem())
        mainMenu.addItem(buildHelpMenuItem())
        return mainMenu
    }

    private func buildApplicationMenuItem() -> NSMenuItem {
        let item = NSMenuItem()
        let menu = NSMenu(title: AppModel.appDisplayName)
        let about = NSMenuItem(title: "About \(AppModel.appDisplayName)",
                               action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)),
                               keyEquivalent: "")
        about.target = NSApp
        menu.addItem(about)
        menu.addItem(.separator())
        let hide = NSMenuItem(title: "Hide \(AppModel.appDisplayName)",
                              action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        hide.target = NSApp
        menu.addItem(hide)
        let hideOthers = NSMenuItem(title: "Hide Others",
                                    action: #selector(NSApplication.hideOtherApplications(_:)),
                                    keyEquivalent: "h")
        hideOthers.keyEquivalentModifierMask = [.command, .option]
        hideOthers.target = NSApp
        menu.addItem(hideOthers)
        let showAll = NSMenuItem(title: "Show All",
                                 action: #selector(NSApplication.unhideAllApplications(_:)),
                                 keyEquivalent: "")
        showAll.target = NSApp
        menu.addItem(showAll)
        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Quit \(AppModel.appDisplayName)",
                              action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        quit.target = NSApp
        menu.addItem(quit)
        item.submenu = menu
        return item
    }

    private func buildHelpMenuItem() -> NSMenuItem {
        let item = NSMenuItem()
        let menu = NSMenu(title: "Help")
        let help = NSMenuItem(title: "\(AppModel.appDisplayName) Help",
                              action: #selector(NSApplication.showHelp(_:)), keyEquivalent: "?")
        help.target = NSApp
        menu.addItem(help)
        item.submenu = menu
        NSApp.helpMenu = menu
        return item
    }
}

// MARK: - NSApplication relaunch

extension NSApplication {
    func relaunch() {
        let url = Bundle.main.bundleURL
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        task.arguments = [url.path]
        try? task.run()
        terminate(nil)
    }
}
