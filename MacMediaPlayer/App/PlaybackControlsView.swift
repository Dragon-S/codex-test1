import AppKit
import Foundation
import SwiftUI

enum PlaybackStatusText {
    static func status(
        for state: PlaybackState,
        localization: AppLocalization = .live
    ) -> String {
        switch state {
        case .idle: localization.text("playback.idle")
        case .loading: localization.text("playback.loading")
        case .playing: localization.text("playback.playing")
        case .paused: localization.text("playback.paused")
        case .stopped: localization.text("playback.stopped")
        case let .failed(failure): self.failure(failure, localization: localization)
        }
    }

    static func announcement(
        for state: PlaybackState,
        localization: AppLocalization = .live
    ) -> String {
        guard case let .failed(failure) = state else {
            return status(for: state, localization: localization)
        }
        return localization.format(
            "playback.failed",
            self.failure(failure, localization: localization)
        )
    }

    static func failure(
        _ failure: PlaybackFailure,
        localization: AppLocalization = .live
    ) -> String {
        switch failure {
        case .unreadable: localization.text("playback.failure.unreadable")
        case .unsupported: localization.text("playback.failure.unsupported")
        case .corrupted: localization.text("playback.failure.corrupted")
        case .decoderInitializationFailed: localization.text("playback.failure.decoder")
        case .engineUnavailable: localization.text("playback.failure.engine")
        }
    }
}

enum PlaybackControlsLayout {
    static let playbackRates = [0.5, 1.0, 1.25, 1.5, 2.0]
    static let seekSteps = [5.0, 10.0, 30.0]
    static let compactContentWidth: CGFloat = 356
    static let groupSpacing: CGFloat = 12
    private static let pickerChromeWidth: CGFloat = 44

    static func speedPickerWidth(localization: AppLocalization) -> CGFloat {
        pickerWidth(
            title: localization.text("速度"),
            options: playbackRates.map(localization.playbackRate)
        )
    }

    static func seekStepPickerWidth(localization: AppLocalization) -> CGFloat {
        pickerWidth(
            title: localization.text("跳转"),
            options: seekSteps.map { seekStepLabel($0, localization: localization) }
        )
    }

    static func seekStepLabel(_ value: Double, localization: AppLocalization) -> String {
        localization.format("duration.seconds", localization.integer(Int(value)))
    }

    static func pickerRowMinimumWidth(localization: AppLocalization) -> CGFloat {
        speedPickerWidth(localization: localization)
            + seekStepPickerWidth(localization: localization)
            + groupSpacing
    }

    private static func pickerWidth(title: String, options: [String]) -> CGFloat {
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: NSFont.systemFontSize),
        ]
        let titleWidth = (title as NSString).size(withAttributes: attributes).width
        let optionWidth = options
            .map { ($0 as NSString).size(withAttributes: attributes).width }
            .max() ?? 0
        return ceil(titleWidth + optionWidth + pickerChromeWidth)
    }
}

struct PlaybackControlsView: View {
    @ObservedObject var coordinator: PlaybackCoordinator
    let openMedia: () -> Void
    let openExternalSubtitle: () -> Void
    let relocateExternalSubtitle: () -> Void
    let localization: AppLocalization

    var body: some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                Button(localization.format("playback.seekBackward", localization.integer(Int(coordinator.seekStep)))) {
                    Task { await coordinator.skipBackward() }
                }
                .accessibilityLabel(localization.format(
                    "playback.seekBackward",
                    localization.integer(Int(coordinator.seekStep))
                ))
                Spacer()
                Button(localization.format("playback.seekForward", localization.integer(Int(coordinator.seekStep)))) {
                    Task { await coordinator.skipForward() }
                }
                .accessibilityLabel(localization.format(
                    "playback.seekForward",
                    localization.integer(Int(coordinator.seekStep))
                ))
            }

            HStack(spacing: 8) {
                Text(timeText(coordinator.position))
                    .monospacedDigit()
                    .frame(minWidth: 44, alignment: .trailing)
                Slider(
                    value: Binding(
                        get: { coordinator.position },
                        set: { value in Task { await coordinator.seek(to: value) } }
                    ),
                    in: 0...max(coordinator.duration, 1)
                )
                .disabled(coordinator.duration <= 0)
                .accessibilityLabel("播放位置")
                .accessibilityValue(
                    localization.format(
                        "accessibility.positionAndDuration",
                        accessibilityTimeText(coordinator.position),
                        accessibilityTimeText(coordinator.duration)
                    )
                )
                .accessibilityHint("调高或调低以定位播放位置")
                Text(timeText(coordinator.duration))
                    .monospacedDigit()
                    .frame(minWidth: 44, alignment: .leading)
            }

            HStack(spacing: 12) {
                Button("打开…", action: openMedia)
                    .keyboardShortcut("o")
                Button("播放") { Task { await coordinator.play() } }
                Button("暂停") { Task { await coordinator.pause() } }
                Spacer()
            }

            HStack(spacing: 12) {
                Button("停止") { Task { await coordinator.stop() } }
                Button("上一首") { Task { await coordinator.previous() } }
                Button("下一首") { Task { await coordinator.next() } }
                Spacer()
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(statusText)
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("播放状态")
                    .accessibilityValue(statusText)
                if let noticeText {
                    Label(noticeText, systemImage: "info.circle.fill")
                        .font(.caption)
                        .labelStyle(SemanticStatusLabelStyle(iconColor: .orange))
                        .accessibilityLabel("轨道提示")
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            HStack(spacing: 12) {
                Picker(localization.text("速度"), selection: Binding(
                    get: { coordinator.playbackRate },
                    set: { rate in Task { await coordinator.setPlaybackRate(rate) } }
                )) {
                    ForEach(PlaybackControlsLayout.playbackRates, id: \.self) { rate in
                        Text(localization.playbackRate(rate)).tag(rate)
                    }
                }
                .frame(minWidth: PlaybackControlsLayout.speedPickerWidth(localization: localization))
                Picker(localization.text("跳转"), selection: Binding(
                    get: { coordinator.seekStep },
                    set: { step in Task { await coordinator.setSeekStep(step) } }
                )) {
                    ForEach(PlaybackControlsLayout.seekSteps, id: \.self) { step in
                        Text(PlaybackControlsLayout.seekStepLabel(step, localization: localization))
                            .tag(step)
                    }
                }
                .frame(minWidth: PlaybackControlsLayout.seekStepPickerWidth(localization: localization))
                Spacer()
            }

            HStack(spacing: 12) {
                Button(localization.text(coordinator.isMuted ? "playback.unmute" : "playback.mute")) {
                    Task { await coordinator.setMuted(!coordinator.isMuted) }
                }
                .accessibilityValue(localization.text(
                    coordinator.isMuted ? "accessibility.muted" : "accessibility.notMuted"
                ))
                Slider(
                    value: Binding(
                        get: { coordinator.playerVolume },
                        set: { volume in Task { await coordinator.setPlayerVolume(volume) } }
                    ),
                    in: 0...1
                )
                .frame(width: 90)
                .accessibilityLabel("播放器音量")
                .accessibilityValue(localization.format(
                    "accessibility.volumePercent",
                    localization.integer(Int(coordinator.playerVolume * 100))
                ))
                .accessibilityHint("调高或调低播放器音量，不会修改系统音量")
                Spacer()
            }

            HStack(spacing: 12) {
                audioTrackMenu
                subtitleMenu
                Spacer()
            }

            playbackFailureRecovery
            playbackQualityNotice
        }
        .buttonStyle(.bordered)
        .padding(12)
        .background(.ultraThinMaterial)
    }

    private func timeText(_ value: TimeInterval) -> String {
        localization.mediaDuration(value)
    }

    private func accessibilityTimeText(_ value: TimeInterval) -> String {
        let seconds = max(0, Int(value.rounded(.down)))
        let hours = seconds / 3_600
        let minutes = (seconds % 3_600) / 60
        let remainingSeconds = seconds % 60
        return [
            hours > 0 ? localization.format("duration.hours", localization.integer(hours)) : nil,
            minutes > 0 ? localization.format("duration.minutes", localization.integer(minutes)) : nil,
            remainingSeconds > 0 || (hours == 0 && minutes == 0)
                ? localization.format("duration.seconds", localization.integer(remainingSeconds))
                : nil,
        ]
        .compactMap { $0 }
        .joined(separator: " ")
    }

    private var audioTrackMenu: some View {
        Menu("音轨") {
            if coordinator.availableAudioTracks.isEmpty {
                Text("没有可用音轨")
            } else {
                ForEach(coordinator.availableAudioTracks) { track in
                    Button {
                        Task { await coordinator.selectAudioTrack(track.id) }
                    } label: {
                        if coordinator.trackSelection.audioTrackID == track.id {
                            Label(localization.audioTrackDisplayName(track), systemImage: "checkmark")
                        } else {
                            Text(localization.audioTrackDisplayName(track))
                        }
                    }
                }
            }
        }
        .disabled(coordinator.nowPlayingList.currentMedia == nil)
        .accessibilityLabel("选择音轨")
        .accessibilityValue(selectedAudioTrackName)
        .accessibilityHint("打开菜单后选择当前媒体的音轨")
    }

    private var subtitleMenu: some View {
        Menu("字幕") {
            Button {
                Task { await coordinator.disableSubtitles() }
            } label: {
                if coordinator.trackSelection.subtitle == .off {
                    Label("关闭字幕", systemImage: "checkmark")
                } else {
                    Text("关闭字幕")
                }
            }
            ForEach(coordinator.availableEmbeddedSubtitleTracks) { track in
                Button {
                    Task { await coordinator.selectEmbeddedSubtitle(track.id) }
                } label: {
                        if coordinator.trackSelection.subtitle == .embedded(track.id) {
                            Label(localization.subtitleTrackDisplayName(track), systemImage: "checkmark")
                        } else {
                            Text(localization.subtitleTrackDisplayName(track))
                    }
                }
            }
            if let externalSubtitleName = coordinator.preferredExternalSubtitleName {
                Label(
                    coordinator.isPreferredExternalSubtitleActive
                        ? localization.format("subtitle.externalShort", externalSubtitleName)
                        : localization.format("subtitle.externalRelocationPending", externalSubtitleName),
                    systemImage: coordinator.isPreferredExternalSubtitleActive
                        ? "checkmark"
                        : "exclamationmark.triangle"
                )
            }
            Divider()
            Button("选择外部字幕…", action: openExternalSubtitle)
            if coordinator.currentExternalSubtitleReferenceID != nil {
                Button("重新定位外部字幕…", action: relocateExternalSubtitle)
            }
        }
        .disabled(coordinator.nowPlayingList.currentMedia == nil)
        .accessibilityLabel("选择字幕")
        .accessibilityValue(selectedSubtitleName)
        .accessibilityHint("打开菜单后选择、关闭或重新定位字幕")
    }

    private var selectedAudioTrackName: String {
        guard let id = coordinator.trackSelection.audioTrackID else {
            return localization.text("track.automatic")
        }
        return coordinator.availableAudioTracks.first(where: { $0.id == id }).map(
            localization.audioTrackDisplayName
        )
            ?? localization.text("track.selectedUnavailable")
    }

    private var selectedSubtitleName: String {
        switch coordinator.trackSelection.subtitle {
        case .off:
            localization.text("subtitle.off")
        case let .embedded(id):
            coordinator.availableEmbeddedSubtitleTracks.first(where: { $0.id == id }).map(
                localization.subtitleTrackDisplayName
            )
                ?? localization.text("subtitle.selectedUnavailable")
        case .external:
            coordinator.preferredExternalSubtitleName.map {
                localization.format("subtitle.externalNamed", $0)
            } ?? localization.text("subtitle.external")
        }
    }

    private var noticeText: String? {
        switch coordinator.trackNotice {
        case .none:
            nil
        case let .preferenceUnavailable(message), let .selectionFailed(message):
            message
        case let .externalSubtitleMissing(name):
            localization.format("subtitle.externalMissing", name)
        case let .externalSubtitleDamaged(name):
            localization.format("subtitle.externalDamaged", name)
        }
    }

    private var statusText: String {
        PlaybackStatusText.status(for: coordinator.state, localization: localization)
    }

    @ViewBuilder
    private var playbackFailureRecovery: some View {
        switch coordinator.playbackFailureNotice {
        case .none:
            EmptyView()
        case let .recovery(recovery):
            VStack(alignment: .leading, spacing: 8) {
                Label(
                    PlaybackStatusText.failure(recovery.failure, localization: localization),
                    systemImage: "exclamationmark.triangle.fill"
                )
                .labelStyle(SemanticStatusLabelStyle(iconColor: .red))
                .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 8) {
                    if recovery.actions.contains(.retry) {
                        Button("重试") {
                            Task { await coordinator.retryPlaybackFailure() }
                        }
                    }
                    if recovery.actions.contains(.revealInFinder) {
                        Button("在 Finder 中显示") {
                            NSWorkspace.shared.activateFileViewerSelecting([recovery.mediaURL])
                        }
                    }
                    Spacer()
                }
                HStack(spacing: 8) {
                    if recovery.actions.contains(.removeEntryFromList) {
                        Button("从列表移除", role: .destructive) {
                            Task { try? await coordinator.removeFailedEntry() }
                        }
                        .help("只移除应用内条目，不删除源文件")
                    }
                    if recovery.actions.contains(.skip) {
                        Button("跳过") {
                            Task { await coordinator.skipPlaybackFailure() }
                        }
                    }
                    Spacer()
                }
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel(localization.format(
                "playback.failed",
                PlaybackStatusText.failure(recovery.failure, localization: localization)
            ))
        case let .exhausted(failures):
            Label(
                localization.format(
                    "playback.exhausted",
                    localization.integer(failures.count)
                ),
                systemImage: "stop.circle.fill"
            )
            .labelStyle(SemanticStatusLabelStyle(iconColor: .red))
            .accessibilityLabel(localization.format(
                "playback.exhausted",
                localization.integer(failures.count)
            ))
        }
    }

    @ViewBuilder
    private var playbackQualityNotice: some View {
        switch coordinator.playbackQualityNotice {
        case .none:
            EmptyView()
        case .softwareDecodingFallback:
            Label(
                "硬件解码初始化失败，正在用软件解码确认媒体质量。",
                systemImage: "gauge.with.dots.needle.33percent"
            )
            .font(.caption)
            .labelStyle(SemanticStatusLabelStyle(iconColor: .orange))
        case .softwareDecodingFallbackFor4K:
            Label(
                "硬件解码初始化失败；4K 已明确降级为软件解码，若播放不稳定请跳过或移除。",
                systemImage: "gauge.with.dots.needle.33percent"
            )
            .font(.caption)
            .labelStyle(SemanticStatusLabelStyle(iconColor: .orange))
        case .softwareDecodingFallbackRequiresFullQualityGate:
            Label(
                "硬件解码初始化失败，已改用软件解码；1080p 及以下仍须通过完整质量门槛。",
                systemImage: "checkmark.seal"
            )
            .font(.caption)
            .labelStyle(SemanticStatusLabelStyle(iconColor: .secondary))
        }
    }
}

struct AudioNowPlayingView: View {
    @ObservedObject var coordinator: PlaybackCoordinator
    let localization: AppLocalization

    var body: some View {
        Group {
            if let presentation = coordinator.mediaPresentation,
               presentation.kind == .audio {
                VStack(spacing: 24) {
                    Spacer(minLength: 32)
                    if !presentation.hasArtwork {
                        Image(systemName: "music.note")
                            .font(.system(size: 88, weight: .light))
                            .foregroundStyle(.secondary)
                            .accessibilityLabel("没有可用封面")
                    }
                    Spacer()
                    VStack(spacing: 6) {
                        Text(presentation.title)
                            .font(.title.bold())
                            .lineLimit(2)
                        if let artist = presentation.artist {
                            Text(artist)
                                .font(.title3)
                        }
                        if let album = presentation.album {
                            Text(album)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)
                    .padding(.vertical, 20)
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
                    .padding(.bottom, 96)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(
                    presentation.hasArtwork
                        ? Color.clear
                        : Color(nsColor: .underPageBackgroundColor)
                )
                .accessibilityElement(children: .combine)
                .accessibilityLabel(audioAccessibilityLabel(presentation))
            }
        }
        .allowsHitTesting(false)
    }

    private func audioAccessibilityLabel(_ presentation: PlaybackMediaPresentation) -> String {
        localization.list([presentation.title, presentation.artist, presentation.album].compactMap { $0 })
    }
}

struct NowPlayingListView: View {
    @ObservedObject var coordinator: PlaybackCoordinator
    let addMediaToPlaylist: (PlaylistID) -> Void
    let importFolderToPlaylist: (PlaylistID) -> Void
    let relocateMissingMedia: (LocalMediaReferenceID) -> Void
    let confirmMediaReplacement: (LocalMediaReferenceID) -> Void
    let cancelMediaReplacement: () -> Void
    let localization: AppLocalization
    @State private var playlistName = ""
    @State private var renameName = ""
    @State private var playlistAwaitingDeletion: PlaylistID?
    @State private var selectedEntryID: PlaylistEntryID?

    private var browsedPlaylist: Playlist? {
        guard let id = coordinator.browsingPlaylistID else { return nil }
        return coordinator.playlists.first(where: { $0.id == id })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Playlist")
                .font(.headline)
                .padding(.horizontal, 12)
                .padding(.top, 12)
            playlistPicker
            Divider()
            if let playlist = browsedPlaylist {
                playlistEditor(playlist)
            } else {
                Text("创建 Playlist，或存储当前正在播放列表。")
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 12)
            }
            Spacer(minLength: 0)
            Divider()
            temporaryListSaver
            persistenceNotice
                .padding(.horizontal, 12)
            missingMediaStatus
                .padding(.horizontal, 12)
                .padding(.bottom, 8)
        }
        .frame(minWidth: 260, idealWidth: 300)
        .background(.ultraThinMaterial)
        .onAppear(perform: chooseInitialPlaylist)
        .onChange(of: coordinator.playlists.map(\.id)) { _, _ in
            chooseInitialPlaylist()
        }
        .onChange(of: coordinator.browsingPlaylistID) { _, _ in
            renameName = browsedPlaylist?.name ?? ""
            selectedEntryID = browsedPlaylist?.currentEntryID
        }
        .onChange(of: browsedPlaylist?.entries.map(\.id)) { _, entryIDs in
            if let selectedEntryID, entryIDs?.contains(selectedEntryID) != true {
                self.selectedEntryID = nil
            }
        }
        .alert(
            "删除正在播放的 Playlist？",
            isPresented: Binding(
                get: { playlistAwaitingDeletion != nil },
                set: { if !$0 { playlistAwaitingDeletion = nil } }
            )
        ) {
            Button("取消", role: .cancel) {
                playlistAwaitingDeletion = nil
            }
            Button("删除", role: .destructive) {
                guard let id = playlistAwaitingDeletion else { return }
                playlistAwaitingDeletion = nil
                Task { try? await coordinator.deletePlaylist(id, confirmed: true) }
            }
        } message: {
            Text("当前媒体会继续播放，但结束后停止；该 Playlist 不会在重启后恢复。源文件不会被删除或修改。")
        }
        .alert(
            missingMediaAlertPresentation?.title ?? "",
            isPresented: Binding(
                get: { missingMediaAlertPresentation != nil },
                set: { isPresented in
                    if !isPresented {
                        coordinator.cancelMissingMediaRecovery()
                        cancelMediaReplacement()
                    }
                }
            )
        ) {
            switch coordinator.missingMediaNotice {
            case let .recoveryRequired(entryID, referenceID):
                Button("取消", role: .cancel) {}
                Button("重新定位…") { relocateMissingMedia(referenceID) }
                Button("从 Playlist 移除", role: .destructive) {
                    guard let playlistID = playlistID(containing: entryID) else { return }
                    Task { try? await coordinator.removeEntry(entryID, from: playlistID) }
                }
            case let .replacementConfirmationRequired(impact):
                Button("取消", role: .cancel) {}
                Button("替换并重置", role: .destructive) {
                    confirmMediaReplacement(impact.referenceID)
                }
            case .none, .noPlayableEntries:
                EmptyView()
            }
        } message: {
            Text(missingMediaAlertPresentation?.message ?? "")
        }
    }

    private var playlistPicker: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 6) {
                ForEach(coordinator.playlists) { playlist in
                    playlistButton(playlist)
                }
            }
            .padding(.horizontal, 12)
        }
    }

    @ViewBuilder
    private func playlistButton(_ playlist: Playlist) -> some View {
        let button = Button {
            coordinator.browsePlaylist(playlist.id)
        } label: {
            Label {
                Text(playlist.name)
            } icon: {
                if coordinator.activePlaylistID == playlist.id {
                    Image(systemName: "speaker.wave.2.fill")
                }
            }
        }
        .accessibilityLabel(localization.format("accessibility.playlistNamed", playlist.name))
        .accessibilityValue(playlistAccessibilityValue(playlist))
        .accessibilityAddTraits(
            coordinator.browsingPlaylistID == playlist.id ? .isSelected : []
        )

        if coordinator.browsingPlaylistID == playlist.id {
            button.buttonStyle(.borderedProminent)
        } else {
            button.buttonStyle(.bordered)
        }
    }

    private func playlistAccessibilityValue(_ playlist: Playlist) -> String {
        var statuses: [String] = []
        if coordinator.browsingPlaylistID == playlist.id {
            statuses.append(localization.text("playlist.browsing"))
        }
        if coordinator.activePlaylistID == playlist.id {
            statuses.append(localization.text("playback.playing"))
        }
        return statuses.isEmpty
            ? localization.text("playlist.notSelected")
            : localization.list(statuses)
    }

    private func playlistEditor(_ playlist: Playlist) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                TextField("Playlist 名称", text: $renameName)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit {
                        Task { try? await coordinator.renamePlaylist(id: playlist.id, to: renameName) }
                    }
                Button("重命名") {
                    Task {
                        try? await coordinator.renamePlaylist(id: playlist.id, to: renameName)
                    }
                }
                .disabled(renameName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .padding(.horizontal, 12)
            HStack {
                Button("添加…") { addMediaToPlaylist(playlist.id) }
                Button("导入文件夹…") { importFolderToPlaylist(playlist.id) }
                Button("删除 Playlist", role: .destructive) {
                    if coordinator.activePlaylistID == playlist.id {
                        playlistAwaitingDeletion = playlist.id
                    } else {
                        Task { try? await coordinator.deletePlaylist(playlist.id, confirmed: false) }
                    }
                }
            }
            .padding(.horizontal, 12)
            VStack(alignment: .leading, spacing: 8) {
                Picker("播放顺序", selection: Binding(
                    get: { playlist.playbackOrder },
                    set: { order in
                        Task { try? await coordinator.setPlaybackOrder(order, for: playlist.id) }
                    }
                )) {
                    Text("顺序").tag(PlaybackOrder.sequential)
                    Text("随机").tag(PlaybackOrder.random)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Picker("重复方式", selection: Binding(
                    get: { playlist.repeatMode },
                    set: { mode in
                        Task { try? await coordinator.setRepeatMode(mode, for: playlist.id) }
                    }
                )) {
                    Text("不重复").tag(PlaylistRepeatMode.none)
                    Text("列表循环").tag(PlaylistRepeatMode.playlist)
                    Text("单条循环").tag(PlaylistRepeatMode.entry)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.horizontal, 12)
            if coordinator.detachedNowPlayingEntry != nil {
                Label("当前媒体是脱离列表的播放项", systemImage: "link.badge.plus")
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 12)
                    .accessibilityLabel("当前媒体是脱离列表的播放项")
            }
            List(Array(playlist.entries.enumerated()), id: \.element.id, selection: $selectedEntryID) { index, entry in
                let presentation = entryPresentation(for: entry, in: playlist)
                let mediaName = URL(fileURLWithPath: entry.media.lastKnownPath).lastPathComponent
                HStack {
                    Image(systemName: presentation.systemImage)
                        .foregroundStyle(presentation.color)
                        .accessibilityHidden(true)
                    Text(mediaName)
                        .lineLimit(1)
                        .foregroundStyle(.primary)
                    if selectedEntryID == entry.id {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(.primary)
                            .help(localization.text("playlist.selected"))
                            .accessibilityLabel(localization.text("playlist.selected"))
                            .accessibilityIdentifier("playlist.entry.selected")
                    }
                    if playlist.currentEntryID == entry.id {
                        Text("当前")
                            .font(.caption2.weight(.semibold))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(.quaternary, in: Capsule())
                    }
                    Spacer()
                    Button {
                        selectedEntryID = entry.id
                        Task { try? await coordinator.playEntry(entry.id, in: playlist.id) }
                    } label: {
                        Image(systemName: "play.fill")
                    }
                    .buttonStyle(.plain)
                    .help("播放")
                    .accessibilityLabel(localization.format("playlist.playItem", mediaName))
                    Button {
                        Task { _ = try? await coordinator.duplicateEntry(entry.id, in: playlist.id) }
                    } label: {
                        Image(systemName: "plus.square.on.square")
                    }
                    .buttonStyle(.plain)
                    .help("刻意重复添加")
                    .accessibilityLabel(localization.format("playlist.duplicateItem", mediaName))
                    Button {
                        Task { try? await coordinator.moveEntry(entry.id, in: playlist.id, to: index - 1) }
                    } label: {
                        Image(systemName: "chevron.up")
                    }
                    .buttonStyle(.plain)
                    .disabled(index == 0)
                    .help("上移")
                    .accessibilityLabel(localization.format("playlist.moveUpItem", mediaName))
                    Button {
                        Task { try? await coordinator.moveEntry(entry.id, in: playlist.id, to: index + 1) }
                    } label: {
                        Image(systemName: "chevron.down")
                    }
                    .buttonStyle(.plain)
                    .disabled(index == playlist.entries.count - 1)
                    .help("下移")
                    .accessibilityLabel(localization.format("playlist.moveDownItem", mediaName))
                    Button(role: .destructive) {
                        Task { try? await coordinator.removeEntry(entry.id, from: playlist.id) }
                    } label: {
                        Image(systemName: "trash")
                    }
                    .buttonStyle(.plain)
                    .help("从 Playlist 移除；不会删除源文件")
                    .accessibilityLabel(localization.format("playlist.removeItem", mediaName))
                    .accessibilityHint("不会删除源文件")
                }
                .tag(entry.id)
                .accessibilityElement(children: .contain)
                .accessibilityLabel(mediaName)
                .accessibilityValue(presentation.accessibilityValue)
            }
            .frame(minHeight: 80)
        }
    }

    private var temporaryListSaver: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("新建或存储")
                .font(.subheadline.weight(.semibold))
            HStack {
                TextField("Playlist 名称", text: $playlistName)
                    .textFieldStyle(.roundedBorder)
                Button("创建") {
                    Task {
                        if (try? await coordinator.createPlaylist(named: playlistName)) != nil {
                            playlistName = ""
                        }
                    }
                }
                .disabled(playlistName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                Button("存储当前") {
                    Task {
                        if (try? await coordinator.saveNowPlayingList(as: playlistName)) != nil {
                            playlistName = ""
                        }
                    }
                }
                .disabled(playlistName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    || coordinator.nowPlayingList.entries.isEmpty
                    || coordinator.activePlaylistID != nil)
            }
        }
        .padding(.horizontal, 12)
    }

    private func isPlaying(_ entryID: PlaylistEntryID, in playlistID: PlaylistID) -> Bool {
        guard coordinator.activePlaylistID == playlistID,
              let index = coordinator.nowPlayingList.currentIndex,
              coordinator.nowPlayingList.entries.indices.contains(index) else { return false }
        return coordinator.nowPlayingList.entries[index].id == entryID
    }

    private func isCurrentPlaybackFailed(_ entryID: PlaylistEntryID, in playlistID: PlaylistID) -> Bool {
        guard isPlaying(entryID, in: playlistID) else { return false }
        if case .failed = coordinator.state {
            return true
        }
        return false
    }

    private struct PlaylistEntryPresentation {
        let systemImage: String
        let color: Color
        let accessibilityValue: String
    }

    private func entryPresentation(
        for entry: PlaylistEntry,
        in playlist: Playlist
    ) -> PlaylistEntryPresentation {
        let isMissing = entry.media.availability == .missing
        let isPlaying = isPlaying(entry.id, in: playlist.id)
        let isCurrent = playlist.currentEntryID == entry.id
        let isUnavailable = !isMissing && (
            isCurrentPlaybackFailed(entry.id, in: playlist.id)
                || playlist.randomRound?.unavailableEntryIDs.contains(entry.id) == true
        )
        var statuses: [String] = []
        if selectedEntryID == entry.id { statuses.append(localization.text("playlist.selected")) }
        if isCurrent { statuses.append(localization.text("playlist.currentItem")) }
        if isPlaying { statuses.append(localization.text("playlist.currentPlayback")) }
        if isMissing { statuses.append(localization.text("playlist.fileMissing")) }
        if isUnavailable { statuses.append(localization.text("playlist.unavailable")) }

        let appearance: (String, Color) = if isMissing {
            ("exclamationmark.triangle.fill", .orange)
        } else if isUnavailable {
            ("xmark.octagon.fill", .red)
        } else if isPlaying {
            ("play.fill", .accentColor)
        } else if isCurrent {
            ("bookmark.fill", .primary)
        } else {
            ("circle", .primary)
        }
        return PlaylistEntryPresentation(
            systemImage: appearance.0,
            color: appearance.1,
            accessibilityValue: localization.list(statuses)
        )
    }

    private func chooseInitialPlaylist() {
        if let browsingID = coordinator.browsingPlaylistID,
           coordinator.playlists.contains(where: { $0.id == browsingID }) {
            renameName = browsedPlaylist?.name ?? ""
            selectedEntryID = browsedPlaylist?.currentEntryID
            return
        }
        if let id = coordinator.activePlaylistID ?? coordinator.playlists.first?.id {
            coordinator.browsePlaylist(id)
        }
    }

    private struct MissingMediaAlertPresentation {
        let title: String
        let message: String
    }

    private var missingMediaAlertPresentation: MissingMediaAlertPresentation? {
        switch coordinator.missingMediaNotice {
        case let .recoveryRequired(entryID, _):
            let name = coordinator.playlists.lazy.flatMap(\.entries)
                .first(where: { $0.id == entryID })
                .map { URL(fileURLWithPath: $0.media.lastKnownPath).lastPathComponent }
                ?? localization.text("media.selectedFile")
            return MissingMediaAlertPresentation(
                title: localization.text("missingMedia.title"),
                message: localization.format("missingMedia.message", name)
            )
        case let .replacementConfirmationRequired(impact):
            return MissingMediaAlertPresentation(
                title: localization.text("replacement.title"),
                message: localization.format(
                    "replacement.message",
                    localization.integer(impact.affectedPlaylistCount),
                    localization.integer(impact.affectedEntryCount)
                )
            )
        case .none, .noPlayableEntries:
            return nil
        }
    }

    private func playlistID(containing entryID: PlaylistEntryID) -> PlaylistID? {
        coordinator.playlists.first(where: { playlist in
            playlist.entries.contains(where: { $0.id == entryID })
        })?.id
    }

    @ViewBuilder
    private var persistenceNotice: some View {
        switch coordinator.persistenceNotice {
        case .none:
            EmptyView()
        case let .saved(name):
            Label(localization.format("playlist.savedAs", name), systemImage: "checkmark.circle.fill")
                .labelStyle(SemanticStatusLabelStyle(iconColor: .green))
        case let .nameAlreadyExists(name):
            Label(localization.format("playlist.nameExists", name), systemImage: "exclamationmark.triangle.fill")
                .labelStyle(SemanticStatusLabelStyle(iconColor: .orange))
        case let .failed(message):
            Label(message, systemImage: "xmark.octagon.fill")
                .labelStyle(SemanticStatusLabelStyle(iconColor: .red))
        }
    }

    @ViewBuilder
    private var missingMediaStatus: some View {
        if case let .noPlayableEntries(missingCount) = coordinator.missingMediaNotice {
            Label(
                localization.format(
                    "accessibility.noPlayableEntries",
                    localization.integer(missingCount)
                ),
                systemImage: "exclamationmark.triangle.fill"
            )
            .labelStyle(SemanticStatusLabelStyle(iconColor: .orange))
        }
    }
}

private struct SemanticStatusLabelStyle: LabelStyle {
    let iconColor: Color

    func makeBody(configuration: Configuration) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            configuration.icon
                .foregroundStyle(iconColor)
            configuration.title
                .foregroundStyle(.primary)
        }
    }
}

struct DisplayAccessibleRoot<Content: View>: View {
    let content: Content
    @ObservedObject var preferences: DisplayAccessibilityPreferences

    var body: some View {
        content
            .transaction { transaction in
                guard preferences.isReduceMotionEnabled else { return }
                transaction.animation = nil
                transaction.disablesAnimations = true
            }
    }
}
