import Combine
import MediaPlayer

enum SystemMediaKeyCommand: Equatable {
    case togglePlayback
    case previous
    case next
}

enum SystemMediaKeyCommandResult: Equatable {
    case success
    case noActionableNowPlayingItem
    case commandFailed
}

@MainActor
final class SystemMediaKeyController {
    private struct CommandRegistration {
        let command: MPRemoteCommand
        let target: Any
    }

    private let coordinator: PlaybackCoordinator
    private let commandCenter: MPRemoteCommandCenter?
    private let nowPlayingInfoCenter: MPNowPlayingInfoCenter?
    private var commandRegistrations: [CommandRegistration] = []
    private var cancellables: Set<AnyCancellable> = []

    init(
        coordinator: PlaybackCoordinator,
        commandCenter: MPRemoteCommandCenter? = .shared(),
        nowPlayingInfoCenter: MPNowPlayingInfoCenter? = .default()
    ) {
        self.coordinator = coordinator
        self.commandCenter = commandCenter
        self.nowPlayingInfoCenter = nowPlayingInfoCenter
        registerCommands()
        observeNowPlayingItem()
    }

    func perform(_ command: SystemMediaKeyCommand) async -> SystemMediaKeyCommandResult {
        let availability = availability(of: command)
        guard availability == .success else { return availability }
        switch command {
        case .togglePlayback:
            await coordinator.togglePlayback()
        case .previous:
            await coordinator.previous()
        case .next:
            await coordinator.next()
        }
        return .success
    }

    func invalidate() {
        guard let commandCenter else { return }
        for registration in commandRegistrations {
            registration.command.removeTarget(registration.target)
        }
        commandRegistrations.removeAll()
        cancellables.removeAll()
        commandCenter.togglePlayPauseCommand.isEnabled = false
        commandCenter.previousTrackCommand.isEnabled = false
        commandCenter.nextTrackCommand.isEnabled = false
        nowPlayingInfoCenter?.nowPlayingInfo = nil
    }

    private func registerCommands() {
        guard let commandCenter else { return }
        commandRegistrations = [
            register(commandCenter.togglePlayPauseCommand, as: .togglePlayback),
            register(commandCenter.previousTrackCommand, as: .previous),
            register(commandCenter.nextTrackCommand, as: .next),
        ]
    }

    private func register(
        _ remoteCommand: MPRemoteCommand,
        as command: SystemMediaKeyCommand
    ) -> CommandRegistration {
        let target = remoteCommand.addTarget { [weak self] _ in
            self?.dispatch(command) ?? .commandFailed
        }
        return CommandRegistration(command: remoteCommand, target: target)
    }

    private func observeNowPlayingItem() {
        coordinator.$nowPlayingList
            .combineLatest(coordinator.$mediaPresentation, coordinator.$state)
            .sink { [weak self] list, presentation, state in
                self?.updateSystemAvailability(
                    list: list,
                    presentation: presentation,
                    state: state
                )
            }
            .store(in: &cancellables)
    }

    private func updateSystemAvailability(
        list: NowPlayingList,
        presentation: PlaybackMediaPresentation?,
        state: PlaybackState
    ) {
        let media = list.hasPlayableCurrentEntry ? list.currentMedia : nil
        let hasCurrentItem = media != nil
        let canTogglePlayback = availability(
            of: .togglePlayback,
            list: list,
            state: state
        ) == .success
        commandCenter?.togglePlayPauseCommand.isEnabled = canTogglePlayback
        commandCenter?.previousTrackCommand.isEnabled = hasCurrentItem
        commandCenter?.nextTrackCommand.isEnabled = hasCurrentItem
        guard let media else {
            nowPlayingInfoCenter?.nowPlayingInfo = nil
            return
        }
        nowPlayingInfoCenter?.nowPlayingInfo = [
            MPMediaItemPropertyTitle: presentation?.title ?? media.url.deletingPathExtension().lastPathComponent,
        ]
    }

    private func dispatch(_ command: SystemMediaKeyCommand) -> MPRemoteCommandHandlerStatus {
        let availability = availability(of: command)
        guard availability == .success else {
            return switch availability {
            case .noActionableNowPlayingItem: .noActionableNowPlayingItem
            case .commandFailed, .success: .commandFailed
            }
        }
        Task { @MainActor [weak self] in
            _ = await self?.perform(command)
        }
        return .success
    }

    private func availability(
        of command: SystemMediaKeyCommand
    ) -> SystemMediaKeyCommandResult {
        availability(
            of: command,
            list: coordinator.nowPlayingList,
            state: coordinator.state
        )
    }

    private func availability(
        of command: SystemMediaKeyCommand,
        list: NowPlayingList,
        state: PlaybackState
    ) -> SystemMediaKeyCommandResult {
        guard list.hasPlayableCurrentEntry else {
            return .noActionableNowPlayingItem
        }
        if command == .togglePlayback {
            switch state {
            case .loading, .failed:
                return .commandFailed
            case .idle, .playing, .paused, .stopped:
                break
            }
        }
        return .success
    }
}
