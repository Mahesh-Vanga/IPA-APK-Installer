import AppKit
import Combine
import ServiceManagement
import SwiftUI

@MainActor final class InstallerDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private var activeModel: InstallerModel?
    private var pendingSnapshot: Data?
    private var renderedInterface = false
    private var replacementInProgress = false
    private var activeHandoff: IdleHandoff?
    private var model: InstallerModel {
        if let activeModel { return activeModel }
        let model = InstallerModel()
        if let pendingSnapshot,
           let restored = try? JSONDecoder().decode(InstallerModel.IdleSnapshot.self, from: pendingSnapshot) {
            model.restore(restored)
        }
        pendingSnapshot = nil
        model.menuBarPreferenceChanged = { [weak self] in self?.setMenuBarEnabled($0) }
        model.workDidFinish = { [weak self] in self?.scheduleIdleReclaim() }
        activeModel = model
        return model
    }
    private var showMenuBar: Bool {
        UserDefaults.standard.object(forKey: "showMenuBar") as? Bool ?? true
    }
    private var statusTap = StatusTapSequence()
    private var backgroundMenuOpen = false
    private weak var appQuitItem: NSMenuItem?
    private var statusItem: NSStatusItem?
    private var panel: InstallerPanel?
    private var pointerExitTimer: Timer?
    private var idleReclaimTask: Task<Void, Never>?
    private var pointerExit = PanelCloseCountdown()
    private var localMouseMonitor: Any?
    private var globalMouseMonitor: Any?
    private var mainWindow: NSWindow?
    private var lastMainWindowFrame: NSRect?
    private var settingsWindow: NSWindow?
    var startsInMenuBar: Bool {
        showMenuBar && (UserDefaults.standard.object(forKey: "startInMenuBar") as? Bool ?? true)
    }

    private func installMainMenu() {
        let bar = NSMenu()
        let appItem = NSMenuItem()
        bar.addItem(appItem)
        let menu = NSMenu(title: "IPA & APK Installer")
        appItem.submenu = menu
        func add(_ title: String, _ action: Selector, _ key: String = "") {
            let item = menu.addItem(withTitle: title, action: action, keyEquivalent: key)
            item.target = self
        }
        add("Open Main Window", #selector(showMainWindow))
        add("Open IPA or APK…", #selector(pickFile), "o")
        add("Refresh Devices", #selector(refreshDevices), "r")
        menu.addItem(.separator())
        add("Settings…", #selector(showSettings), ",")
        menu.addItem(.separator())
        add(showMenuBar ? "Quit to Menu Bar" : "Quit IPA & APK Installer", #selector(quitToMenuBar), "q")
        appQuitItem = menu.items.last
        NSApp.mainMenu = bar
    }

    @objc private func pickFile() { showMainWindow(); model.pick() }
    @objc private func refreshDevices() { model.refresh() }

    @objc private func quitToMenuBar() {
        guard statusItem?.button != nil else { stopBackground(); return }
        closePanel()
        mainWindow?.close()
        settingsWindow?.close()
        NSApp.setActivationPolicy(.accessory)
    }

    @objc private func stopBackground() {
        idleReclaimTask?.cancel()
        activeHandoff?.remove()
        closePanel()
        NSApp.terminate(nil)
    }

    private func present(_ window: NSWindow) {
        closePanel()
        markInterfaceInUse()
        if NSApp.activationPolicy() != .regular { NSApp.setActivationPolicy(.regular) }
        if appQuitItem == nil { installMainMenu() }
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
    }

    @objc private func showMainWindow() { openMainWindow(detachingFrom: nil) }

    private func openMainWindow(detachingFrom detachedFrame: NSRect?) {
        if mainWindow == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 390, height: 540),
                                  styleMask: [.titled, .closable, .miniaturizable, .resizable],
                                  backing: .buffered, defer: false)
            window.title = "IPA & APK Installer"
            window.isReleasedWhenClosed = false
            window.delegate = self
            window.titleVisibility = .hidden
            window.contentViewController = NSHostingController(rootView: InstallerSurface(
                model: model, openMain: nil,
                openSettings: { [weak self] in self?.showSettings() }))
            window.setContentSize(NSSize(width: 390, height: 540))
            window.contentMinSize = NSSize(width: 360, height: 420)
            if let lastMainWindowFrame, let screen = NSScreen.screens.first(where: { $0.visibleFrame.intersects(lastMainWindowFrame) }) {
                window.setFrame(window.constrainFrameRect(lastMainWindowFrame, to: screen), display: false)
            } else {
                window.center()
            }
            mainWindow = window
        }
        guard let mainWindow else { return }
        if let detachedFrame {
            var frame = mainWindow.frame
            // Align the content with the preview rather than pushing it down by the title bar.
            let chrome = frame.height - mainWindow.contentRect(forFrameRect: frame).height
            frame.origin = NSPoint(x: detachedFrame.minX, y: detachedFrame.maxY + chrome - frame.height)
            let pointer = NSEvent.mouseLocation
            if let screen = NSScreen.screens.first(where: { $0.frame.contains(pointer) }) {
                let safe = screen.visibleFrame
                frame.origin.x = min(max(frame.minX, safe.minX), max(safe.minX, safe.maxX - frame.width))
                frame.origin.y = min(max(frame.minY, safe.minY), max(safe.minY, safe.maxY - frame.height))
            }
            mainWindow.setFrame(frame, display: false)
        }
        present(mainWindow)
    }

    @objc private func showSettings() {
        if settingsWindow == nil {
            let window = NSWindow(contentViewController: NSHostingController(rootView: InstallerSettings(model: model)))
            window.title = "IPA & APK Installer Settings"
            window.styleMask = [.titled, .closable]
            window.isReleasedWhenClosed = false
            window.delegate = self
            window.center()
            settingsWindow = window
        }
        if let settingsWindow { present(settingsWindow) }
    }

    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }
        if window === mainWindow {
            lastMainWindowFrame = window.frame
            mainWindow = nil
        } else if window === settingsWindow {
            settingsWindow = nil
        }
        // Detach after AppKit finishes delivering the close event.
        Task { @MainActor [weak self] in
            window.contentViewController = nil
            window.contentView = nil
            self?.scheduleIdleReclaim()
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag && !replacementInProgress { showMainWindow() }
        return true
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NotificationCenter.default.addObserver(self, selector: #selector(closePanel),
            name: NSApplication.didChangeScreenParametersNotification, object: nil)
        if IdleHandoff.isContinuation {
            replacementInProgress = true
            Task { @MainActor [weak self] in await self?.resumeIdleBackground() }
            return
        }
        setMenuBarEnabled(showMenuBar)
        if !startsInMenuBar { showMainWindow() }
    }

    private func setMenuBarEnabled(_ enabled: Bool) {
        appQuitItem?.title = enabled ? "Quit to Menu Bar" : "Quit IPA & APK Installer"
        if !enabled {
            closePanel()
            statusTap.reset()
            if let statusItem { NSStatusBar.system.removeStatusItem(statusItem) }
            statusItem = nil
            return
        }
        guard statusItem == nil else { return }
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        guard let button = item.button else { NSStatusBar.system.removeStatusItem(item); return }
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        button.target = self
        button.action = #selector(statusButtonClicked(_:))
        let icon = StatusDropButton(frame: button.bounds)
        icon.autoresizingMask = [.width, .height]
        icon.isBordered = false
        icon.image = StatusGlyph.makeImage()
        icon.image?.isTemplate = true
        icon.imagePosition = .imageOnly
        icon.toolTip = "IPA & APK Installer — drop an IPA or APK. Double-tap or secondary-click for Quit."
        icon.setAccessibilityLabel("IPA & APK Installer")
        icon.sendAction(on: [.leftMouseUp])
        icon.target = self
        icon.action = #selector(statusButtonClicked(_:))
        icon.onSecondaryClick = { [weak self, weak button] event in
            guard let self, let button else { return }
            self.statusTap.reset()
            self.showBackgroundMenu(at: button, contextEvent: event)
        }
        icon.onPointerHover = { [weak self] in self?.revealDropPanel() }
        icon.registerForDraggedTypes([.fileURL])
        icon.canAccept = { [weak self] in self.map { $0.activeModel?.busy != true } ?? false }
        icon.onDragHover = { [weak self] in self?.revealDropPanel() }
        icon.onDrop = { [weak self] urls in
            guard let self else { return false }
            self.markInterfaceInUse()
            let accepted = self.model.selectDropped(urls)
            if accepted { self.openPopover() }
            return accepted
        }
        button.addSubview(icon)
        statusItem = item
    }

    private func revealDropPanel() {
        guard !backgroundMenuOpen, !model.busy else { return }
        model.showDropPrompt = true
        openPopover(passive: true)
    }

    @objc private func statusButtonClicked(_ sender: NSButton) {
        guard !backgroundMenuOpen else { return }
        let icon = sender as? StatusDropButton
        icon?.cancelPointerHover()
        let event = icon?.pressEvent ?? NSApp.currentEvent
        let isSecondary = event?.type == .rightMouseUp || event?.type == .rightMouseDown
        let isDoubleTap: Bool
        if let event, event.type == .leftMouseDown || event.type == .leftMouseUp {
            isDoubleTap = statusTap.isDoubleTap(at: event.timestamp, count: event.clickCount,
                                                interval: NSEvent.doubleClickInterval)
        } else {
            isDoubleTap = false
        }
        if isSecondary || isDoubleTap {
            statusTap.reset()
            closePanel()
            // Let the button finish processing the release before native menu tracking begins.
            Task { @MainActor [weak self] in
                guard let self, let anchor = self.statusItem?.button else { return }
                self.showBackgroundMenu(at: anchor)
            }
            return
        }
        showDropPanel()
    }

    private func showBackgroundMenu(at button: NSButton, contextEvent: NSEvent? = nil) {
        guard !backgroundMenuOpen else { return }
        closePanel()
        backgroundMenuOpen = true
        defer { backgroundMenuOpen = false }
        let menu = NSMenu(title: "IPA & APK Installer")
        let quit = menu.addItem(withTitle: "Quit IPA & APK Installer",
                                action: #selector(stopBackground), keyEquivalent: "")
        quit.target = self
        if let contextEvent {
            NSMenu.popUpContextMenu(menu, with: contextEvent, for: button)
            return
        }
        let y = button.isFlipped ? button.bounds.maxY : button.bounds.minY
        menu.popUp(positioning: nil, at: NSPoint(x: button.bounds.minX, y: y), in: button)
    }

    private func showDropPanel() {
        // Do not shift focus between taps. Panel controls can take focus when used.
        guard panel?.isVisible != true else { return }
        model.showDropPrompt = !model.busy
        openPopover(passive: true)
    }

    @objc private func closePanel() {
        panel?.dragStartFrame = nil
        pointerExit.reset()
        pointerExitTimer?.invalidate()
        pointerExitTimer = nil
        if let closing = panel {
            panel = nil
            closing.orderOut(nil)
            Task { @MainActor [weak self] in
                closing.contentViewController = nil
                closing.contentView = nil
                closing.close()
                self?.scheduleIdleReclaim()
            }
        }
        activeModel?.showDropPrompt = false
        if let localMouseMonitor { NSEvent.removeMonitor(localMouseMonitor) }
        if let globalMouseMonitor { NSEvent.removeMonitor(globalMouseMonitor) }
        localMouseMonitor = nil
        globalMouseMonitor = nil
    }

    private func markInterfaceInUse() {
        renderedInterface = true
        idleReclaimTask?.cancel()
        idleReclaimTask = nil
    }

    private var canResetBackground: Bool {
        renderedInterface && showMenuBar && !backgroundMenuOpen &&
        panel == nil && mainWindow == nil && settingsWindow == nil &&
        activeModel?.busy != true && NSApp.modalWindow == nil && NSEvent.pressedMouseButtons == 0
    }

    private func scheduleIdleReclaim() {
        guard canResetBackground, idleReclaimTask == nil, !replacementInProgress else { return }
        idleReclaimTask = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: .seconds(8)) }
            catch { return }
            guard let self else { return }
            defer { self.idleReclaimTask = nil }
            guard self.canResetBackground else { return }
            if let button = self.statusItem?.button, let window = button.window,
               window.convertToScreen(button.convert(button.bounds, to: nil)).contains(NSEvent.mouseLocation) {
                return
            }
            await self.resetBackground()
        }
    }

    private func resetBackground() async {
        guard !replacementInProgress, let activeModel else { return }
        replacementInProgress = true
        defer { replacementInProgress = false }
        var handoff: IdleHandoff?
        var replacement: NSRunningApplication?
        var surrenderedIcon = false
        var succeeded = false
        defer {
            handoff?.remove()
            activeHandoff = nil
            if !succeeded {
                _ = replacement?.terminate()
                if surrenderedIcon && showMenuBar { setMenuBarEnabled(true) }
            }
        }
        do {
            let transfer = try IdleHandoff.create(with: JSONEncoder().encode(activeModel.idleSnapshot()))
            handoff = transfer
            activeHandoff = transfer
            let launch = NSWorkspace.OpenConfiguration()
            launch.activates = false
            launch.addsToRecentItems = false
            launch.createsNewApplicationInstance = true
            launch.arguments = [IdleHandoff.argument, transfer.id.uuidString]
            replacement = try await NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: launch)
            try await transfer.waitFor("ready")
            try Task.checkCancellation()
            guard canResetBackground else { return }
            if let button = statusItem?.button, let window = button.window,
               window.convertToScreen(button.convert(button.bounds, to: nil)).contains(NSEvent.mouseLocation) { return }
            // The old icon stays available until the replacement has loaded state.
            setMenuBarEnabled(false)
            surrenderedIcon = true
            try transfer.signal("go")
            try await transfer.waitFor("active")
            succeeded = true
            transfer.remove()
            activeHandoff = nil
            NSApp.terminate(nil)
        } catch {
            // Keep the original instance and its session if the reset cannot finish.
        }
    }

    private func resumeIdleBackground() async {
        do {
            guard let handoff = IdleHandoff.fromArguments else { throw CocoaError(.fileReadCorruptFile) }
            let state = try handoff.readSnapshot()
            try handoff.signal("ready")
            try await handoff.waitFor("go")
            pendingSnapshot = state
            setMenuBarEnabled(showMenuBar)
            guard statusItem != nil else { throw CocoaError(.featureUnsupported) }
            try handoff.signal("active")
            replacementInProgress = false
        } catch {
            NSApp.terminate(nil)
        }
    }

    private func openPopover(passive: Bool = false) {
        guard panel?.isVisible != true, let anchor = statusItem?.button,
              let window = anchor.window else { return }
        markInterfaceInUse()
        let anchorRect = window.convertToScreen(anchor.convert(anchor.bounds, to: nil))
        guard let screen = NSScreen.screens.first(where: {
            $0.frame.contains(NSPoint(x: anchorRect.midX, y: anchorRect.midY))
        }) ?? window.screen else { return }
        let frame = menuPanelFrame(anchor: anchorRect, visible: screen.visibleFrame)
        let panel = InstallerPanel(contentRect: frame,
            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.level = .popUpMenu
        panel.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary, .transient]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isFloatingPanel = true
        panel.isMovable = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.dismiss = { [weak self] in self?.closePanel() }
        panel.contentViewController = NSHostingController(rootView: InstallerSurface(
            model: model,
            openMain: { [weak self] in self?.showMainWindow() },
            openSettings: { [weak self] in self?.showSettings() },
            detachableHeader: true
        )
          .clipShape(RoundedRectangle(cornerRadius: 14))
          .overlay(RoundedRectangle(cornerRadius: 14)
              .strokeBorder(.primary.opacity(0.14)).allowsHitTesting(false))
          .frame(width: frame.width, height: frame.height))
        panel.setFrame(frame, display: false)
        self.panel = panel
        if passive { panel.orderFrontRegardless() }
        else { panel.makeKeyAndOrderFront(nil) }

        // Sample only while open. This also works while Finder owns a drag
        // and when moving onto another app without clicking.
        let delay = PanelCloseDelay(rawValue: UserDefaults.standard.integer(forKey: "panelCloseDelayMS")) ?? .immediate
        pointerExit = PanelCloseCountdown(delay: Double(delay.rawValue) / 1_000)
        pointerExitTimer = Timer.scheduledTimer(timeInterval: 1.0 / 30, target: self,
            selector: #selector(checkPointerExit(_:)), userInfo: nil, repeats: true)
        pointerExitTimer?.tolerance = 0.004

        let clicks: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        localMouseMonitor = NSEvent.addLocalMonitorForEvents(matching: clicks) { [weak self] event in
            if event.window !== self?.panel && event.window !== self?.statusItem?.button?.window {
                self?.closePanel()
            }
            return event
        }
        globalMouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: clicks) { [weak self] _ in
            Task { @MainActor in self?.closePanel() }
        }
    }

    @objc private func checkPointerExit(_ timer: Timer) {
        guard let panel, panel.isVisible, let anchor = statusItem?.button,
              let window = anchor.window else { closePanel(); return }
        if let start = panel.dragStartFrame {
            pointerExit.reset()
            // AppKit's window drag may consume mouse-up. Check the physical
            // button state instead, and do not auto-dismiss during the drag.
            if NSEvent.pressedMouseButtons & 1 != 0 { return }
            panel.dragStartFrame = nil
            let moved = panel.frame
            if abs(moved.minX - start.minX) >= 4 || abs(moved.minY - start.minY) >= 4 {
                openMainWindow(detachingFrom: moved)
                return
            }
            panel.setFrameOrigin(start.origin)
        }
        guard NSApp.modalWindow == nil else { pointerExit.reset(); return }
        let iconRect = window.convertToScreen(anchor.convert(anchor.bounds, to: nil))
        let inside = menuPanelContainsPointer(NSEvent.mouseLocation, anchor: iconRect, panel: panel.frame)
        if pointerExit.shouldClose(pointerInside: inside, now: ProcessInfo.processInfo.systemUptime) {
            closePanel()
        }
    }

}

@MainActor private final class InstallerPanel: NSPanel {
    var dismiss: (() -> Void)?
    weak var dragHandle: NSView?
    var dragStartFrame: NSRect?

    override func sendEvent(_ event: NSEvent) {
        if event.type == .leftMouseDown, let dragHandle,
           dragHandle.bounds.contains(dragHandle.convert(event.locationInWindow, from: nil)) {
            dragStartFrame = frame
            performDrag(with: event)
            return
        }
        super.sendEvent(event)
    }
    override var canBecomeKey: Bool { true }
    override func cancelOperation(_ sender: Any?) { dismiss?() }
}

@MainActor private final class StatusDropButton: NSButton {
    var canAccept: () -> Bool = { false }
    var onDrop: ([URL]) -> Bool = { _ in false }
    var onDragHover: () -> Void = {}
    var onPointerHover: () -> Void = {}
    var onSecondaryClick: ((NSEvent) -> Void)?

    override func rightMouseDown(with event: NSEvent) {
        cancelPointerHover()
        onSecondaryClick?(event)
    }
    private(set) var pressEvent: NSEvent?
    override func mouseDown(with event: NSEvent) {
        pressEvent = event
        defer { pressEvent = nil }
        super.mouseDown(with: event)
    }

    private var pointerTracking: NSTrackingArea?
    private var pointerTask: Task<Void, Never>?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let pointerTracking { removeTrackingArea(pointerTracking) }
        let area = NSTrackingArea(rect: .zero,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect, .enabledDuringMouseDrag],
            owner: self, userInfo: nil)
        addTrackingArea(area)
        pointerTracking = area
    }

    override func mouseEntered(with event: NSEvent) {
        super.mouseEntered(with: event)
        pointerTask?.cancel()
        pointerTask = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(280)) }
            catch { return }
            guard let self, let window = self.window, window.isVisible else { return }
            let point = window.convertPoint(fromScreen: NSEvent.mouseLocation)
            if self.bounds.contains(self.convert(point, from: nil)) { self.onPointerHover() }
        }
    }

    func cancelPointerHover() {
        pointerTask?.cancel()
        pointerTask = nil
    }

    override func mouseExited(with event: NSEvent) {
        cancelPointerHover()
        super.mouseExited(with: event)
    }

    private var hoverTask: Task<Void, Never>?
    private var handledHover = false
    private var dragSnapshot: (sequence: Int, change: Int, eligible: Bool)?

    private func endHover() {
        hoverTask?.cancel()
        hoverTask = nil
        handledHover = false
        dragSnapshot = nil
        highlight(false)
    }

    private func urls(_ sender: NSDraggingInfo) -> [URL] {
        (sender.draggingPasteboard.readObjects(forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
    }

    private func eligible(_ files: [URL]) -> Bool {
        files.count == 1 && ["ipa", "apk"].contains(files[0].pathExtension.lowercased())
    }

    private func acceptsHover(_ sender: NSDraggingInfo) -> Bool {
        guard canAccept() else { return false }
        let sequence = sender.draggingSequenceNumber
        let change = sender.draggingPasteboard.changeCount
        if let dragSnapshot, dragSnapshot.sequence == sequence, dragSnapshot.change == change {
            return dragSnapshot.eligible
        }
        let isEligible = eligible(urls(sender))
        dragSnapshot = (sequence, change, isEligible)
        return isEligible
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { draggingUpdated(sender) }
    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        let accepted = acceptsHover(sender)
        guard accepted else { endHover(); return [] }
        if hoverTask == nil && !handledHover {
            highlight(true)
            hoverTask = Task { [weak self] in
                do { try await Task.sleep(for: .milliseconds(180)) }
                catch { return }
                guard let self else { return }
                self.hoverTask = nil
                self.handledHover = true
                if self.canAccept(), self.window?.isVisible == true { self.onDragHover() }
            }
        }
        return accepted ? .copy : []
    }
    override func draggingExited(_ sender: NSDraggingInfo?) { endHover() }
    override func draggingEnded(_ sender: NSDraggingInfo) { endHover() }
    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool { canAccept() && eligible(urls(sender)) }
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        endHover()
        let files = urls(sender)
        guard canAccept(), eligible(files) else { return false }
        return onDrop(files)
    }
}

@MainActor private struct PanelDragHandle: NSViewRepresentable {
    func makeNSView(context: Context) -> Grip { Grip() }
    func updateNSView(_ view: Grip, context: Context) {}

    final class Grip: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            (window as? InstallerPanel)?.dragHandle = self
        }

        override func resetCursorRects() { addCursorRect(bounds, cursor: .openHand) }
    }
}

@MainActor private struct InstallerSurface: View {
    @ObservedObject var model: InstallerModel
    let openMain: (() -> Void)?
    let openSettings: () -> Void
    var detachableHeader = false

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("IPA & APK Installer").font(.headline)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .overlay {
                        if detachableHeader {
                            PanelDragHandle()
                                .help("Drag down to open as a window")
                                .accessibilityHidden(true)
                        }
                    }
                if let openMain { Button("Main Window", action: openMain) }
                Button(action: openSettings) { Image(systemName: "gearshape").accessibilityLabel("Settings") }.help("Settings")
            }.padding(12)
            Divider()
            InstallerView(model: model, inPopover: openMain != nil)
        }
        .background(.regularMaterial)
    }
}

@MainActor struct InstallerSettings: View {
    @ObservedObject var model: InstallerModel
    @AppStorage("panelCloseDelayMS") private var panelCloseDelay = PanelCloseDelay.immediate
    @AppStorage("showMenuBarDiagnostics") private var showMenuBarDiagnostics = false
    @AppStorage("startInMenuBar") private var startInMenuBar = true
    @AppStorage("refreshOnDrop") private var refreshOnDrop = true
    @AppStorage("selectOnlyDevice") private var selectOnlyDevice = true
    @State private var loginStatus = SMAppService.mainApp.status
    @State private var loginError: String?

    private var launchAtLogin: Binding<Bool> {
        Binding(get: { loginStatus == .enabled || loginStatus == .requiresApproval }, set: { enabled in
            loginError = nil
            do {
                if enabled { try SMAppService.mainApp.register() }
                else { try SMAppService.mainApp.unregister() }
            } catch { loginError = error.localizedDescription }
            loginStatus = SMAppService.mainApp.status
        })
    }

    var body: some View {
        Form {
            Section("General") {
                Toggle("Show installer in menu bar", isOn: $model.showMenuBar)
                Toggle("Start in menu bar without opening the main window", isOn: $startInMenuBar)
                    .disabled(!model.showMenuBar)
                Picker("Close menu bar panel after pointer leaves", selection: $panelCloseDelay) {
                    ForEach(PanelCloseDelay.allCases, id: \.self) { delay in
                        Text(delay.label).tag(delay)
                    }
                }.disabled(!model.showMenuBar)
                Toggle("Show Diagnostics in menu bar panel", isOn: $showMenuBarDiagnostics)
                Toggle("Launch at login", isOn: launchAtLogin)
                    .disabled(loginStatus == .notFound)
                if loginStatus == .notFound {
                    Text("Launch at login is unavailable for this copy. Install the app in Applications.")
                        .foregroundStyle(.secondary)
                }
                if loginStatus == .requiresApproval {
                    Button("Approve in System Settings…") { SMAppService.openSystemSettingsLoginItems() }
                }
                if let loginError { Text(loginError).foregroundStyle(.red) }
            }
            UpdateSettings()
            Section("Installation") {
                Toggle("Refresh devices when I drop a package", isOn: $refreshOnDrop)
                Toggle("Select the only available compatible device", isOn: $selectOnlyDevice)
                Text("Dropping a file never installs it. Install on Device starts installation directly on the selected device. Test-only APK permission resets when you choose a file.")
                    .font(.callout).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 480)
        .fixedSize(horizontal: false, vertical: true)
        .onAppear { loginStatus = SMAppService.mainApp.status }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            loginStatus = SMAppService.mainApp.status
        }
    }
}
