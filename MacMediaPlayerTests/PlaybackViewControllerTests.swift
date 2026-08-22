import AppKit
import Testing
@testable import MacMediaPlayer

@MainActor
struct PlaybackViewControllerTests {
    @Test("应用菜单提供标准打开与全屏快捷键")
    func applicationMenuProvidesStandardCommandShortcuts() throws {
        let menu = AppDelegate(localization: AppLocalization(
            languageIdentifier: "zh-Hans",
            locale: Locale(identifier: "zh_CN")
        )).makeMainMenu()
        let fileMenu = try #require(menu.item(withTitle: "文件")?.submenu)
        let openItem = try #require(fileMenu.item(withTitle: "打开…"))
        #expect(openItem.keyEquivalent == "o")
        #expect(semanticModifiers(openItem.keyEquivalentModifierMask) == .command)

        let viewMenu = try #require(menu.item(withTitle: "显示")?.submenu)
        let fullScreenItem = try #require(viewMenu.item(withTitle: "进入全屏"))
        #expect(fullScreenItem.keyEquivalent == "f")
        #expect(semanticModifiers(fullScreenItem.keyEquivalentModifierMask) == [.control, .command])

        let englishMenu = AppDelegate(localization: AppLocalization(
            languageIdentifier: "en",
            locale: Locale(identifier: "en_US")
        )).makeMainMenu()
        let englishFileMenu = try #require(englishMenu.item(withTitle: "File")?.submenu)
        #expect(englishFileMenu.item(withTitle: "Open…")?.keyEquivalent == "o")
        let englishViewMenu = try #require(englishMenu.item(withTitle: "View")?.submenu)
        #expect(englishViewMenu.item(withTitle: "Enter Full Screen")?.keyEquivalent == "f")
    }

    @Test("根播放区域可接收焦点并显示焦点环")
    func playbackAreaHasVisibleKeyboardFocus() {
        let controller = makeController()
        controller.loadViewIfNeeded()

        #expect(controller.view.acceptsFirstResponder)
        #expect(controller.view.focusRingType == .exterior)
    }

    @Test("视频画布以当前媒体播放区域暴露给 VoiceOver")
    func playbackCanvasExposesMediaAreaSemantics() {
        let controller = makeController()
        controller.loadViewIfNeeded()

        #expect(controller.videoView.isAccessibilityElement())
        #expect(controller.videoView.accessibilityRole() == .group)
        #expect(controller.videoView.accessibilityLabel() == "当前媒体播放区域")

        let englishController = makeController(localization: AppLocalization(
            languageIdentifier: "en",
            locale: Locale(identifier: "en_US")
        ))
        englishController.loadViewIfNeeded()
        #expect(englishController.videoView.accessibilityLabel() == "Current media playback area")
        #expect(englishController.view.accessibilityLabel() == "Player")
    }

    @Test("当前条目、播放状态与静音变化通过播放器元素通知 VoiceOver")
    func criticalPlaybackChangesUpdateAccessibleAnnouncement() async throws {
        let engine = LayoutFakePlaybackEngine()
        let coordinator = PlaybackCoordinator(engine: engine)
        let controller = makeController(coordinator: coordinator)
        controller.loadViewIfNeeded()

        #expect(controller.view.isAccessibilityElement())
        #expect(controller.view.accessibilityRole() == .group)
        #expect(controller.view.accessibilityLabel() == "播放器")

        await coordinator.open(LocalMedia(url: URL(fileURLWithPath: "/tmp/夜航.mp4")))
        try await expectAccessibilityAnnouncement(
            "当前条目：夜航.mp4，第 1 项，共 1 项",
            from: controller
        )
        #expect(controller.videoView.accessibilityValue() as? String == "夜航.mp4")

        await engine.sendState(.playing)
        try await expectAccessibilityAnnouncement("正在播放", from: controller)

        await coordinator.setMuted(true)
        try await expectAccessibilityAnnouncement("已静音", from: controller)

        await engine.sendState(.paused)
        try await expectAccessibilityAnnouncement("已暂停", from: controller)
    }

    @Test("重复媒体条目切换时 VoiceOver 仍可分辨当前位置")
    func duplicateMediaChangesExposeCurrentEntryPosition() async throws {
        let engine = LayoutFakePlaybackEngine()
        let coordinator = PlaybackCoordinator(engine: engine)
        let controller = makeController(coordinator: coordinator)
        controller.loadViewIfNeeded()
        let media = LocalMedia(url: URL(fileURLWithPath: "/tmp/重复.mp4"))

        await coordinator.open([media, media])
        try await expectAccessibilityAnnouncement(
            "当前条目：重复.mp4，第 1 项，共 2 项",
            from: controller
        )

        await coordinator.next()

        try await expectAccessibilityAnnouncement(
            "当前条目：重复.mp4，第 2 项，共 2 项",
            from: controller
        )
    }

    @Test("文件缺失与持久化失败会请求 VoiceOver 播报")
    func recoveryBlockingChangesUpdateAccessibleAnnouncement() async throws {
        let missingReference = PersistentLocalMediaReference(
            id: LocalMediaReferenceID(),
            bookmark: Data("bookmark".utf8),
            lastKnownPath: "/tmp/失联.mp4",
            availability: .missing
        )
        let missingEntry = PlaylistEntry(media: missingReference)
        let playlist = Playlist(name: "待看", entries: [missingEntry])
        let coordinator = PlaybackCoordinator(
            engine: LayoutFakePlaybackEngine(),
            playlistStore: InMemoryPlaylistStore(library: PlaylistLibrary(playlists: [playlist]))
        )
        let controller = makeController(coordinator: coordinator)
        controller.loadViewIfNeeded()
        try await coordinator.restorePersistentState()

        try await coordinator.playEntry(missingEntry.id, in: playlist.id)

        try await expectAccessibilityAnnouncement("文件缺失：失联.mp4", from: controller)

        let unavailableCoordinator = PlaybackCoordinator(
            engine: LayoutFakePlaybackEngine(),
            playlistStore: UnavailablePlaylistStore(message: "持久化离线")
        )
        let unavailableController = makeController(coordinator: unavailableCoordinator)
        unavailableController.loadViewIfNeeded()
        _ = try? await unavailableCoordinator.createPlaylist(named: "失败")

        try await expectAccessibilityAnnouncement("存储失败：持久化离线", from: unavailableController)
    }

    @Test("核心播放键只匹配规定按键与修饰组合")
    func matchesCorePlaybackShortcutsExactly() throws {
        #expect(PlaybackKeyboardShortcut(event: try keyEvent(keyCode: 49, characters: " ")) == .togglePlayback)
        #expect(PlaybackKeyboardShortcut(event: try keyEvent(keyCode: 123, characters: "")) == .skipBackward)
        #expect(PlaybackKeyboardShortcut(event: try keyEvent(keyCode: 124, characters: "")) == .skipForward)
        #expect(PlaybackKeyboardShortcut(event: try keyEvent(keyCode: 126, characters: "")) == .increasePlayerVolume)
        #expect(PlaybackKeyboardShortcut(event: try keyEvent(keyCode: 125, characters: "")) == .decreasePlayerVolume)
        #expect(PlaybackKeyboardShortcut(event: try keyEvent(keyCode: 35, characters: "p")) == .togglePlaylist)
        #expect(PlaybackKeyboardShortcut(event: try keyEvent(
            keyCode: 3,
            characters: "f",
            modifiers: [.control, .command]
        )) == .toggleFullScreen)
        #expect(PlaybackKeyboardShortcut(event: try keyEvent(
            keyCode: 31,
            characters: "o",
            modifiers: .command
        )) == .openMedia)

        #expect(PlaybackKeyboardShortcut(event: try keyEvent(
            keyCode: 49,
            characters: " ",
            modifiers: .option
        )) == nil)
        #expect(PlaybackKeyboardShortcut(event: try keyEvent(
            keyCode: 35,
            characters: "p",
            modifiers: .command
        )) == nil)
        #expect(PlaybackKeyboardShortcut(event: try keyEvent(keyCode: 31, characters: "o")) == nil)
    }

    @Test("键盘命令驱动播放接缝并保留局部 Playlist 与打开操作")
    func performsKeyboardCommandsThroughPublicActions() async {
        let engine = LayoutFakePlaybackEngine()
        let coordinator = PlaybackCoordinator(engine: engine)
        var openCount = 0
        let controller = makeController(
            coordinator: coordinator,
            openMedia: { openCount += 1 }
        )
        controller.loadViewIfNeeded()
        let media = LocalMedia(url: URL(fileURLWithPath: "/tmp/keyboard.mp4"))
        await coordinator.open(media)

        await controller.performKeyboardShortcut(.togglePlayback)
        await controller.performKeyboardShortcut(.skipForward)
        await controller.performKeyboardShortcut(.decreasePlayerVolume)
        await controller.performKeyboardShortcut(.togglePlaylist)
        await controller.performKeyboardShortcut(.openMedia)

        let commands = await engine.commands
        #expect(commands.contains(.load(media)))
        #expect(commands.contains(.play))
        #expect(commands.contains(.seek(10)))
        #expect(commands.contains(.setPlayerVolume(0.95)))
        #expect(!controller.isPlaylistVisible)
        #expect(openCount == 1)
    }

    @Test("文本输入优先消费 Space 而不触发全局播放")
    func textInputTakesPrecedenceOverGlobalPlaybackShortcut() async throws {
        let engine = LayoutFakePlaybackEngine()
        let coordinator = PlaybackCoordinator(engine: engine)
        let controller = makeController(coordinator: coordinator)
        let window = host(controller, size: NSSize(width: 800, height: 500))
        let textField = NSTextField(frame: NSRect(x: 20, y: 20, width: 200, height: 24))
        controller.view.addSubview(textField)
        window.makeKeyAndOrderFront(nil)
        #expect(window.makeFirstResponder(textField))

        let event = try keyEvent(
            keyCode: 49,
            characters: " ",
            windowNumber: window.windowNumber
        )
        #expect(!window.performKeyEquivalent(with: event))
        window.sendEvent(event)

        #expect(textField.stringValue == " ")
        #expect(await engine.commands.isEmpty)
        window.orderOut(nil)
    }

    @Test("不相关的子视图吞掉 keyDown 前窗口仍执行全局播放快捷键")
    func windowHandlesGlobalShortcutBeforeUnrelatedChildView() async throws {
        let engine = LayoutFakePlaybackEngine()
        let coordinator = PlaybackCoordinator(engine: engine)
        let controller = makeController(coordinator: coordinator)
        let window = host(controller, size: NSSize(width: 800, height: 500))
        let child = ShortcutSwallowingView(frame: NSRect(x: 20, y: 20, width: 100, height: 100))
        controller.view.addSubview(child)
        #expect(window.makeFirstResponder(child))
        await coordinator.open(LocalMedia(url: URL(fileURLWithPath: "/tmp/global.mp4")))

        #expect(window.performKeyEquivalent(with: try keyEvent(
            keyCode: 49,
            characters: " ",
            windowNumber: window.windowNumber
        )))
        for _ in 0..<100 where !(await engine.commands.contains(.play)) {
            await Task.yield()
        }

        #expect(await engine.commands.contains(.play))
    }

    @Test("Button 的 Space 局部语义优先于全局播放")
    func buttonSpaceTakesPrecedenceOverGlobalPlaybackShortcut() throws {
        let controller = makeController()
        let window = host(controller, size: NSSize(width: 800, height: 500))
        let button = NSButton(title: "局部操作", target: nil, action: nil)
        controller.view.addSubview(button)
        #expect(window.makeFirstResponder(button))

        #expect(!window.performKeyEquivalent(with: try keyEvent(
            keyCode: 49,
            characters: " ",
            windowNumber: window.windowNumber
        )))
    }

    @Test("普通窗口收起 Playlist 后画布恢复完整宽度")
    func collapsingPlaylistRestoresCanvasWidth() {
        let controller = makeController()
        let size = NSSize(width: 1_000, height: 700)
        let window = host(controller, size: size)
        layout(controller, in: window, size: size)
        #expect(!controller.isCanvasUsingFullWidth)

        controller.setPlaylistVisible(false)
        layout(controller, in: window, size: size)

        #expect(controller.isCanvasUsingFullWidth)
        #expect(!controller.isPlaylistVisible)
        #expect(window.contentView === controller.view)
    }

    @Test("默认英文窗口为 Playlist 操作按钮保留完整宽度")
    func defaultEnglishWindowReservesFullPlaylistActionWidth() throws {
        let controller = makeController(localization: AppLocalization(
            languageIdentifier: "en",
            locale: Locale(identifier: "en_US")
        ))
        let size = NSSize(width: 960, height: 600)
        let window = host(controller, size: size)
        layout(controller, in: window, size: size)
        let sidebar = try #require(controller.view.subviews.first {
            $0.accessibilityLabel() == "Playlist sidebar"
        })

        #expect(sidebar.frame.width >= 320)
    }

    @Test("打开 Playlist 侧栏时焦点进入侧栏，关闭时返回触发按钮")
    func playlistSidebarMovesFocusInAndBack() throws {
        let controller = makeController()
        let window = host(controller, size: NSSize(width: 1_000, height: 700))
        controller.setPlaylistVisible(false)
        let toggleButton = try #require(controller.view.subviews
            .compactMap { $0 as? NSButton }
            .first { $0.title == "显示 Playlist" })
        #expect(toggleButton.accessibilityLabel() == "显示 Playlist")
        #expect(toggleButton.accessibilityValue() as? String == "已折叠")
        #expect(window.makeFirstResponder(toggleButton))

        controller.setPlaylistVisible(true)

        #expect(toggleButton.accessibilityLabel() == "隐藏 Playlist")
        #expect(toggleButton.accessibilityValue() as? String == "已展开")

        let sidebar = try #require(controller.view.subviews.first {
            $0.accessibilityLabel() == "Playlist 侧栏"
        })
        #expect(sidebar.isAccessibilityElement())
        #expect(sidebar.accessibilityRole() == .group)
        #expect(window.firstResponder === sidebar)

        controller.setPlaylistVisible(false)

        #expect(window.firstResponder === toggleButton)
    }

    @Test("关闭重定位面板后焦点返回原触发控件")
    func relocationPanelReturnsFocusToTrigger() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        let trigger = NSButton(title: "重新定位…", target: nil, action: nil)
        let panelControl = NSTextField(string: "面板内容")
        window.contentView?.addSubview(trigger)
        window.contentView?.addSubview(panelControl)
        #expect(window.makeFirstResponder(trigger))
        let focusReturn = WindowAccessibilityFocusReturn(window: window)
        #expect(window.makeFirstResponder(panelControl))

        #expect(focusReturn.restore())

        #expect(window.firstResponder === trigger)
    }

    @Test("重定位面板优先返回捕获的 VoiceOver 焦点")
    func relocationPanelPrefersCapturedAccessibilityFocus() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        let voiceOverTrigger = NSButton(title: "重新定位外部字幕…", target: nil, action: nil)
        let keyboardFocus = NSTextField(string: "键盘焦点")
        let panelControl = NSTextField(string: "面板内容")
        window.contentView?.addSubview(voiceOverTrigger)
        window.contentView?.addSubview(keyboardFocus)
        window.contentView?.addSubview(panelControl)
        #expect(window.makeFirstResponder(keyboardFocus))
        let focusReturn = WindowAccessibilityFocusReturn(
            window: window,
            accessibilityFocusedElement: voiceOverTrigger
        )
        #expect(window.makeFirstResponder(panelControl))

        #expect(focusReturn.restore())
        #expect(window.firstResponder === voiceOverTrigger)
    }

    @Test("触发控件失效时不声称焦点已恢复")
    func focusReturnReportsFailedRestoration() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        let trigger = ConditionalFirstResponderView(frame: NSRect(x: 0, y: 0, width: 80, height: 24))
        let panelControl = NSTextField(string: "面板内容")
        window.contentView?.addSubview(trigger)
        window.contentView?.addSubview(panelControl)
        #expect(window.makeFirstResponder(trigger))
        let focusReturn = WindowAccessibilityFocusReturn(window: window)
        #expect(window.makeFirstResponder(panelControl))
        trigger.allowsFirstResponder = false

        #expect(!focusReturn.restore())
        #expect(window.firstResponder !== trigger)
    }

    @Test("全屏 Playlist 以覆盖层显示且不改变画布尺寸")
    func fullscreenPlaylistOverlaysCanvasWithoutResizingIt() {
        let controller = makeController()
        let size = NSSize(width: 1_200, height: 800)
        let window = host(controller, size: size)
        controller.setFullScreenMode(true)
        controller.setPlaylistVisible(false)
        layout(controller, in: window, size: size)
        let canvasFrameWithoutPlaylist = controller.videoView.frame

        controller.setPlaylistVisible(true)
        layout(controller, in: window, size: size)

        #expect(controller.videoView.frame == canvasFrameWithoutPlaylist)
        #expect(controller.videoView.frame == controller.view.bounds)
        _ = window
    }

    @Test("全屏 Esc 依次关闭 Playlist 与控制器后才退出全屏")
    func escapeDismissesOverlaysBeforeExitingFullscreen() {
        let controller = makeController()
        controller.loadViewIfNeeded()
        controller.setFullScreenMode(true)

        #expect(controller.handleEscapeKey() == .dismissedPlaylist)
        #expect(!controller.isPlaylistVisible)
        #expect(controller.isControlsVisible)

        #expect(controller.handleEscapeKey() == .dismissedControls)
        #expect(!controller.isControlsVisible)

        controller.handlePointerActivity()
        #expect(controller.isControlsVisible)
        _ = controller.handleEscapeKey()
        #expect(controller.handleEscapeKey() == .exitFullScreen)
    }

    @Test("全屏控制区隐藏时焦点迁回可见播放区域")
    func hidingFullscreenControlsMovesFocusToPlaybackArea() throws {
        let controller = makeController()
        let window = host(controller, size: NSSize(width: 1_000, height: 700))
        controller.setFullScreenMode(true)
        controller.setPlaylistVisible(false)
        let playlistToggle = try #require(controller.view.subviews
            .compactMap { $0 as? NSButton }
            .first { $0.title == "显示 Playlist" })
        #expect(window.makeFirstResponder(playlistToggle))

        #expect(controller.handleEscapeKey() == .dismissedControls)

        #expect(window.firstResponder === controller.view)
        #expect(controller.view.focusRingType == .exterior)
    }

    @Test("生产偏好监听工作区的显示辅助功能通知")
    func displayPreferencesObserveWorkspaceAccessibilityChanges() {
        let displayOptions = MutableDisplayOptions()
        let displayPreferences = DisplayAccessibilityPreferences(
            reduceMotionProvider: { displayOptions.shouldReduceMotion }
        )
        #expect(!displayPreferences.isReduceMotionEnabled)

        displayOptions.shouldReduceMotion = true
        NSWorkspace.shared.notificationCenter.post(
            name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification,
            object: NSWorkspace.shared
        )

        #expect(displayPreferences.isReduceMotionEnabled)
    }

    @Test("运行中切换外观与减弱动态效果会保留播放上下文和焦点")
    func displayPreferenceChangesPreservePlaybackContextAndFocus() async throws {
        let displayOptions = MutableDisplayOptions()
        let notifications = NotificationCenter()
        let displayPreferences = DisplayAccessibilityPreferences(
            notificationCenter: notifications,
            reduceMotionProvider: { displayOptions.shouldReduceMotion }
        )
        let engine = LayoutFakePlaybackEngine()
        let coordinator = PlaybackCoordinator(engine: engine)
        let controller = makeController(
            coordinator: coordinator,
            displayPreferences: displayPreferences
        )
        let window = host(controller, size: NSSize(width: 1_000, height: 700))
        window.appearance = NSAppearance(named: .aqua)
        window.contentView?.layoutSubtreeIfNeeded()
        #expect(controller.view.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .aqua)
        await coordinator.open(LocalMedia(url: URL(fileURLWithPath: "/tmp/appearance.mp4")))
        await engine.sendState(.playing)
        await engine.sendTimeline(position: 42, duration: 120)
        try await expectPlaybackContext(
            state: .playing,
            position: 42,
            coordinator: coordinator
        )
        controller.setPlaylistVisible(false)
        #expect(window.makeFirstResponder(controller.view))
        let commandsBeforeChanges = await engine.commands

        window.appearance = NSAppearance(named: .darkAqua)
        window.contentView?.layoutSubtreeIfNeeded()
        #expect(controller.view.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua)

        displayOptions.shouldReduceMotion = true
        notifications.post(name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil)

        #expect(controller.isReduceMotionEnabled)
        #expect(coordinator.state == .playing)
        #expect(coordinator.position == 42)
        #expect(!controller.isPlaylistVisible)
        #expect(window.firstResponder === controller.view)
        #expect(await engine.commands == commandsBeforeChanges)
        #expect(controller.videoView.appearance == nil)
    }

    private func makeController(
        coordinator: PlaybackCoordinator? = nil,
        openMedia: @escaping () -> Void = {},
        displayPreferences: DisplayAccessibilityPreferences = DisplayAccessibilityPreferences(),
        localization: AppLocalization = AppLocalization(
            languageIdentifier: "zh-Hans",
            locale: Locale(identifier: "zh_CN")
        )
    ) -> PlaybackViewController {
        let coordinator = coordinator ?? PlaybackCoordinator(engine: LayoutFakePlaybackEngine())
        return PlaybackViewController(
            coordinator: coordinator,
            openMedia: openMedia,
            openExternalSubtitle: {},
            relocateExternalSubtitle: {},
            addMediaToPlaylist: { _ in },
            relocateMissingMedia: { _ in },
            confirmMediaReplacement: { _ in },
            cancelMediaReplacement: {},
            videoView: PlaybackCanvasView(frame: .zero),
            displayPreferences: displayPreferences,
            localization: localization
        )
    }

    private func host(_ controller: PlaybackViewController, size: NSSize) -> NSWindow {
        let window = PlaybackWindow(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.titled, .resizable],
            backing: .buffered,
            defer: false
        )
        controller.loadViewIfNeeded()
        controller.installKeyboardHandling(on: window)
        window.contentView = controller.view
        window.setContentSize(size)
        window.contentView?.layoutSubtreeIfNeeded()
        return window
    }

    private func layout(
        _ controller: PlaybackViewController,
        in window: NSWindow,
        size: NSSize
    ) {
        window.contentMinSize = size
        window.contentMaxSize = size
        window.setContentSize(size)
        controller.view.setFrameSize(size)
        controller.view.needsLayout = true
        controller.view.layoutSubtreeIfNeeded()
    }

    private func keyEvent(
        keyCode: UInt16,
        characters: String,
        modifiers: NSEvent.ModifierFlags = [],
        windowNumber: Int = 0
    ) throws -> NSEvent {
        try #require(NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: modifiers,
            timestamp: 0,
            windowNumber: windowNumber,
            context: nil,
            characters: characters,
            charactersIgnoringModifiers: characters,
            isARepeat: false,
            keyCode: keyCode
        ))
    }

    private func semanticModifiers(
        _ modifiers: NSEvent.ModifierFlags
    ) -> NSEvent.ModifierFlags {
        modifiers.intersection([.command, .control, .option, .shift])
    }

    private func expectAccessibilityAnnouncement(
        _ expected: String,
        from controller: PlaybackViewController
    ) async throws {
        for _ in 0..<100 where controller.view.accessibilityValue() as? String != expected {
            try await Task.sleep(for: .milliseconds(1))
        }
        #expect(controller.view.accessibilityValue() as? String == expected)
    }

    private func expectPlaybackContext(
        state: PlaybackState,
        position: TimeInterval,
        coordinator: PlaybackCoordinator
    ) async throws {
        for _ in 0..<100 where coordinator.state != state || coordinator.position != position {
            try await Task.sleep(for: .milliseconds(1))
        }
        #expect(coordinator.state == state)
        #expect(coordinator.position == position)
    }

}

@MainActor
private final class MutableDisplayOptions {
    var shouldReduceMotion = false
}

private final class ShortcutSwallowingView: NSView {
    override var acceptsFirstResponder: Bool { true }

    override func keyDown(with event: NSEvent) {}
}

private final class ConditionalFirstResponderView: NSView {
    var allowsFirstResponder = true

    override var acceptsFirstResponder: Bool { allowsFirstResponder }

    override func becomeFirstResponder() -> Bool { allowsFirstResponder }
}

private enum LayoutEngineCommand: Equatable, Sendable {
    case load(LocalMedia)
    case play
    case pause
    case stop
    case seek(TimeInterval)
    case setPlayerVolume(Double)
}

private actor LayoutFakePlaybackEngine: PlaybackEngine {
    private(set) var commands: [LayoutEngineCommand] = []
    private var loadID: PlaybackLoadID?
    nonisolated let events: AsyncStream<PlaybackEngineEvent>
    private let continuation: AsyncStream<PlaybackEngineEvent>.Continuation

    init() {
        (events, continuation) = AsyncStream.makeStream()
    }

    func load(_ media: LocalMedia, loadID: PlaybackLoadID) {
        commands.append(.load(media))
        self.loadID = loadID
    }
    func play() { commands.append(.play) }
    func pause() { commands.append(.pause) }
    func stop() { commands.append(.stop) }
    func seek(to position: TimeInterval) { commands.append(.seek(position)) }
    func setPlaybackRate(_ rate: Double) {}
    func setPlayerVolume(_ volume: Double) { commands.append(.setPlayerVolume(volume)) }
    func setMuted(_ isMuted: Bool) {}

    func sendState(_ state: PlaybackState) {
        guard let loadID else { return }
        continuation.yield(.playbackStateChanged(state, loadID: loadID))
    }

    func sendTimeline(position: TimeInterval, duration: TimeInterval) {
        guard let loadID else { return }
        continuation.yield(.timelineChanged(position: position, duration: duration, loadID: loadID))
    }
}
