import AppKit
import Testing
@testable import MacMediaPlayer

@MainActor
struct PlaybackViewControllerTests {
    @Test("应用菜单提供标准打开与全屏快捷键")
    func applicationMenuProvidesStandardCommandShortcuts() throws {
        let menu = AppDelegate().makeMainMenu()
        let fileMenu = try #require(menu.item(withTitle: "文件")?.submenu)
        let openItem = try #require(fileMenu.item(withTitle: "打开…"))
        #expect(openItem.keyEquivalent == "o")
        #expect(semanticModifiers(openItem.keyEquivalentModifierMask) == .command)

        let viewMenu = try #require(menu.item(withTitle: "显示")?.submenu)
        let fullScreenItem = try #require(viewMenu.item(withTitle: "进入全屏"))
        #expect(fullScreenItem.keyEquivalent == "f")
        #expect(semanticModifiers(fullScreenItem.keyEquivalentModifierMask) == [.control, .command])
    }

    @Test("根播放区域可接收焦点并显示焦点环")
    func playbackAreaHasVisibleKeyboardFocus() {
        let controller = makeController()
        controller.loadViewIfNeeded()

        #expect(controller.view.acceptsFirstResponder)
        #expect(controller.view.focusRingType == .exterior)
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

    private func makeController(
        coordinator: PlaybackCoordinator? = nil,
        openMedia: @escaping () -> Void = {}
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
            videoView: PlaybackCanvasView(frame: .zero)
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
}

private final class ShortcutSwallowingView: NSView {
    override var acceptsFirstResponder: Bool { true }

    override func keyDown(with event: NSEvent) {}
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
    nonisolated let events: AsyncStream<PlaybackEngineEvent>

    init() {
        events = AsyncStream { _ in }
    }

    func load(_ media: LocalMedia, loadID: PlaybackLoadID) {
        commands.append(.load(media))
    }
    func play() { commands.append(.play) }
    func pause() { commands.append(.pause) }
    func stop() { commands.append(.stop) }
    func seek(to position: TimeInterval) { commands.append(.seek(position)) }
    func setPlaybackRate(_ rate: Double) {}
    func setPlayerVolume(_ volume: Double) { commands.append(.setPlayerVolume(volume)) }
    func setMuted(_ isMuted: Bool) {}
}
