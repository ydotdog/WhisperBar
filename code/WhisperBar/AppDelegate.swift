import AppKit
import SwiftUI

// NSHostingView subclass that accepts the first mouse click
// so buttons in a non-activating NSPanel respond on the first click
private class ClickThroughHostingView<T: View>: NSHostingView<T> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var acceptsFirstResponder: Bool { true }
}

@MainActor
class AppDelegate: NSObject, NSApplicationDelegate {
    let engine = TranscriptionEngine()
    let vocabulary = VocabularyStore()
    let recordingStore = RecordingStore()
    private var panel: NSPanel?
    private var vocabWindow: NSWindow?
    private var recordingsWindow: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        engine.vocabularyStore = vocabulary
        engine.recordingStore = recordingStore
        createPanel()
        setupHotkey()

        NotificationCenter.default.addObserver(
            forName: .openRecordings, object: nil, queue: .main
        ) { [weak self] _ in self?.openRecordingsWindow() }
        NotificationCenter.default.addObserver(
            forName: .openVocabulary, object: nil, queue: .main
        ) { [weak self] _ in self?.openVocabularyWindow() }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    // MARK: - Floating Panel

    private func createPanel() {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 500, height: 80),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        let rootView = VoiceBarView(
            onOpenVocabulary: { [weak self] in self?.openVocabularyWindow() },
            onOpenRecordings: { [weak self] in self?.openRecordingsWindow() }
        )
        .environmentObject(engine)

        let hostingView = ClickThroughHostingView(rootView: rootView)
        hostingView.autoresizingMask = [.width, .height]
        hostingView.wantsLayer = true
        hostingView.layer?.backgroundColor = .clear
        panel.contentView = hostingView

        panel.level = .floating
        panel.isFloatingPanel = true
        panel.becomesKeyOnlyIfNeeded = true
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false                // SwiftUI handles rounded shadow
        panel.isMovableByWindowBackground = true // drag anywhere on the bar
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]

        positionPanel(panel)
        panel.orderFront(nil)
        self.panel = panel

        // Auto-resize panel height when content changes
        hostingView.setFrameSize(hostingView.fittingSize)
        NotificationCenter.default.addObserver(
            forName: NSView.frameDidChangeNotification,
            object: hostingView, queue: .main
        ) { [weak panel, weak hostingView] _ in
            guard let panel, let hv = hostingView else { return }
            let ideal = hv.fittingSize
            var frame = panel.frame
            let dy = ideal.height - frame.height
            frame.origin.y -= dy
            frame.size.height = ideal.height
            frame.size.width = ideal.width
            panel.setFrame(frame, display: true, animate: false)
        }
    }

    private func positionPanel(_ panel: NSPanel) {
        guard let screen = NSScreen.main else { return }
        let visible = screen.visibleFrame
        let ideal = (panel.contentView as? NSHostingView<AnyView>)?.fittingSize
                    ?? CGSize(width: 500, height: 80)
        let x = visible.midX - ideal.width / 2
        let y = visible.minY + 12
        panel.setFrame(NSRect(x: x, y: y, width: ideal.width, height: ideal.height),
                       display: true)
    }

    // MARK: - Recordings Window

    func openRecordingsWindow() {
        if let existing = recordingsWindow {
            existing.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 500),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "录音记录"
        window.contentView = NSHostingView(
            rootView: RecordingsView()
                .environmentObject(recordingStore)
                .environmentObject(engine)
        )
        window.center()
        window.isReleasedWhenClosed = false
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        recordingsWindow = window
    }

    // MARK: - Vocabulary Window

    func openVocabularyWindow() {
        if let existing = vocabWindow {
            existing.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 440, height: 480),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "自定义词汇"
        window.contentView = NSHostingView(
            rootView: VocabularyView().environmentObject(vocabulary)
        )
        window.center()
        window.isReleasedWhenClosed = false
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        vocabWindow = window
    }

    // MARK: - Global Hotkey

    private func setupHotkey() {
        // Space bar long-press: push-to-talk
        GlobalHotkeyManager.shared.onSpaceDown = { [weak self] in
            DispatchQueue.main.async { self?.engine.handleHotkeyDown() }
        }
        GlobalHotkeyManager.shared.onSpaceUp = { [weak self] in
            DispatchQueue.main.async { self?.engine.handleHotkeyUp() }
        }
        // ⌥⌘R: toggle recording
        GlobalHotkeyManager.shared.onHotkeyPressed = { [weak self] in
            DispatchQueue.main.async { self?.engine.handleToggleHotkey() }
        }
        GlobalHotkeyManager.shared.register()
    }
}
