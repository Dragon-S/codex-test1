import Foundation
import SwiftUI

struct PlaybackControlsView: View {
    @ObservedObject var coordinator: PlaybackCoordinator
    let openMedia: () -> Void
    let openExternalSubtitle: () -> Void
    let relocateExternalSubtitle: () -> Void

    var body: some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                Button("后退 \(Int(coordinator.seekStep)) 秒") {
                    Task { await coordinator.skipBackward() }
                }
                .accessibilityLabel("后退 \(Int(coordinator.seekStep)) 秒")
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
                .accessibilityValue("\(timeText(coordinator.position))，总时长 \(timeText(coordinator.duration))")
                Text(timeText(coordinator.duration))
                    .monospacedDigit()
                    .frame(minWidth: 44, alignment: .leading)
                Button("前进 \(Int(coordinator.seekStep)) 秒") {
                    Task { await coordinator.skipForward() }
                }
                .accessibilityLabel("前进 \(Int(coordinator.seekStep)) 秒")
            }

            HStack(spacing: 12) {
                Button("打开…", action: openMedia)
                    .keyboardShortcut("o")
                Button("播放") { Task { await coordinator.play() } }
                Button("暂停") { Task { await coordinator.pause() } }
                Button("停止") { Task { await coordinator.stop() } }
                Button("上一首") { Task { await coordinator.previous() } }
                Button("下一首") { Task { await coordinator.next() } }
                Picker("速度", selection: Binding(
                    get: { coordinator.playbackRate },
                    set: { rate in Task { await coordinator.setPlaybackRate(rate) } }
                )) {
                    Text("0.5×").tag(0.5)
                    Text("1×").tag(1.0)
                    Text("1.25×").tag(1.25)
                    Text("1.5×").tag(1.5)
                    Text("2×").tag(2.0)
                }
                .frame(width: 105)
                Picker("跳转", selection: Binding(
                    get: { coordinator.seekStep },
                    set: { step in Task { await coordinator.setSeekStep(step) } }
                )) {
                    Text("5 秒").tag(5.0)
                    Text("10 秒").tag(10.0)
                    Text("30 秒").tag(30.0)
                }
                .frame(width: 100)
                Button(coordinator.isMuted ? "取消静音" : "静音") {
                    Task { await coordinator.setMuted(!coordinator.isMuted) }
                }
                Slider(
                    value: Binding(
                        get: { coordinator.playerVolume },
                        set: { volume in Task { await coordinator.setPlayerVolume(volume) } }
                    ),
                    in: 0...1
                )
                .frame(width: 90)
                .accessibilityLabel("播放器音量")
                .accessibilityValue("\(Int(coordinator.playerVolume * 100))%")
                audioTrackMenu
                subtitleMenu
                Spacer()
                VStack(alignment: .trailing, spacing: 2) {
                    Text(statusText)
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("播放状态")
                    .accessibilityValue(statusText)
                    if let noticeText {
                        Text(noticeText)
                            .font(.caption)
                            .foregroundStyle(.orange)
                            .accessibilityLabel("轨道提示")
                    }
                }
            }
        }
        .buttonStyle(.bordered)
        .padding(12)
        .background(.ultraThinMaterial)
    }

    private func timeText(_ value: TimeInterval) -> String {
        let seconds = max(0, Int(value.rounded(.down)))
        let hours = seconds / 3_600
        let minutes = (seconds % 3_600) / 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, seconds % 60)
        }
        return String(format: "%d:%02d", minutes, seconds % 60)
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
                            Label(track.displayName, systemImage: "checkmark")
                        } else {
                            Text(track.displayName)
                        }
                    }
                }
            }
        }
        .disabled(coordinator.nowPlayingList.currentMedia == nil)
        .accessibilityLabel("选择音轨")
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
                        Label(track.displayName, systemImage: "checkmark")
                    } else {
                        Text(track.displayName)
                    }
                }
            }
            if let externalSubtitleName = coordinator.preferredExternalSubtitleName {
                Label(
                    coordinator.isPreferredExternalSubtitleActive
                        ? "外部：\(externalSubtitleName)"
                        : "外部字幕待重新定位：\(externalSubtitleName)",
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
    }

    private var noticeText: String? {
        switch coordinator.trackNotice {
        case .none:
            nil
        case let .preferenceUnavailable(message), let .selectionFailed(message):
            message
        case let .externalSubtitleMissing(name):
            "外部字幕“\(name)”缺失；可重新定位或停用字幕"
        case let .externalSubtitleDamaged(name):
            "外部字幕“\(name)”已损坏；媒体将继续播放"
        }
    }

    private var statusText: String {
        switch coordinator.state {
        case .idle: "尚未打开媒体"
        case .loading: "正在载入"
        case .playing: "正在播放"
        case .paused: "已暂停"
        case .stopped: "已停止"
        case let .failed(failure): failureText(failure)
        }
    }

    private func failureText(_ failure: PlaybackFailure) -> String {
        switch failure {
        case .unreadable: "无法读取文件"
        case .unsupported: "不支持此媒体"
        case .corrupted: "媒体内容已损坏"
        case .decoderInitializationFailed: "解码器初始化失败"
        case .engineUnavailable: "播放引擎不可用"
        }
    }
}

struct NowPlayingListView: View {
    @ObservedObject var coordinator: PlaybackCoordinator
    let addMediaToPlaylist: (PlaylistID) -> Void
    let relocateMissingMedia: (LocalMediaReferenceID) -> Void
    let confirmMediaReplacement: (LocalMediaReferenceID) -> Void
    let cancelMediaReplacement: () -> Void
    @State private var playlistName = ""
    @State private var renameName = ""
    @State private var playlistAwaitingDeletion: PlaylistID?

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
        .onAppear(perform: chooseInitialPlaylist)
        .onChange(of: coordinator.playlists.map(\.id)) { _, _ in
            chooseInitialPlaylist()
        }
        .onChange(of: coordinator.browsingPlaylistID) { _, _ in
            renameName = browsedPlaylist?.name ?? ""
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
            missingMediaAlertTitle,
            isPresented: Binding(
                get: { missingMediaAlertIsPresented },
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
            Text(missingMediaAlertMessage)
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
        .accessibilityValue(coordinator.activePlaylistID == playlist.id
            ? "正在播放的 Playlist" : "")

        if coordinator.browsingPlaylistID == playlist.id {
            button.buttonStyle(.borderedProminent)
        } else {
            button.buttonStyle(.bordered)
        }
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
                Button("删除 Playlist", role: .destructive) {
                    if coordinator.activePlaylistID == playlist.id {
                        playlistAwaitingDeletion = playlist.id
                    } else {
                        Task { try? await coordinator.deletePlaylist(playlist.id, confirmed: false) }
                    }
                }
            }
            .padding(.horizontal, 12)
            HStack {
                Picker("播放顺序", selection: Binding(
                    get: { playlist.playbackOrder },
                    set: { order in
                        Task { try? await coordinator.setPlaybackOrder(order, for: playlist.id) }
                    }
                )) {
                    Text("顺序").tag(PlaybackOrder.sequential)
                    Text("随机").tag(PlaybackOrder.random)
                }
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
            }
            .padding(.horizontal, 12)
            if coordinator.detachedNowPlayingEntry != nil {
                Label("当前媒体是脱离列表的播放项", systemImage: "link.badge.plus")
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 12)
                    .accessibilityLabel("当前媒体是脱离列表的播放项")
            }
            List(Array(playlist.entries.enumerated()), id: \.element.id) { index, entry in
                HStack {
                    Image(systemName: entry.media.availability == .missing
                        ? "exclamationmark.triangle.fill"
                        : (isPlaying(entry.id, in: playlist.id) ? "play.fill" : "circle"))
                        .foregroundStyle(entry.media.availability == .missing ? .orange : .primary)
                        .accessibilityHidden(true)
                    Text(URL(fileURLWithPath: entry.media.lastKnownPath).lastPathComponent)
                        .lineLimit(1)
                    Spacer()
                    Button {
                        Task { try? await coordinator.playEntry(entry.id, in: playlist.id) }
                    } label: {
                        Image(systemName: "play.fill")
                    }
                    .buttonStyle(.plain)
                    .help("播放")
                    Button {
                        Task { _ = try? await coordinator.duplicateEntry(entry.id, in: playlist.id) }
                    } label: {
                        Image(systemName: "plus.square.on.square")
                    }
                    .buttonStyle(.plain)
                    .help("刻意重复添加")
                    Button {
                        Task { try? await coordinator.moveEntry(entry.id, in: playlist.id, to: index - 1) }
                    } label: {
                        Image(systemName: "chevron.up")
                    }
                    .buttonStyle(.plain)
                    .disabled(index == 0)
                    .help("上移")
                    Button {
                        Task { try? await coordinator.moveEntry(entry.id, in: playlist.id, to: index + 1) }
                    } label: {
                        Image(systemName: "chevron.down")
                    }
                    .buttonStyle(.plain)
                    .disabled(index == playlist.entries.count - 1)
                    .help("下移")
                    Button(role: .destructive) {
                        Task { try? await coordinator.removeEntry(entry.id, from: playlist.id) }
                    } label: {
                        Image(systemName: "trash")
                    }
                    .buttonStyle(.plain)
                    .help("从 Playlist 移除；不会删除源文件")
                }
                .accessibilityLabel(URL(fileURLWithPath: entry.media.lastKnownPath).lastPathComponent)
                .accessibilityValue(entry.media.availability == .missing
                    ? "文件缺失"
                    : (isPlaying(entry.id, in: playlist.id) ? "当前播放" : ""))
            }
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

    private func chooseInitialPlaylist() {
        if let browsingID = coordinator.browsingPlaylistID,
           coordinator.playlists.contains(where: { $0.id == browsingID }) {
            renameName = browsedPlaylist?.name ?? ""
            return
        }
        if let id = coordinator.activePlaylistID ?? coordinator.playlists.first?.id {
            coordinator.browsePlaylist(id)
        }
    }

    private var missingMediaAlertIsPresented: Bool {
        switch coordinator.missingMediaNotice {
        case .recoveryRequired, .replacementConfirmationRequired:
            true
        case .none, .noPlayableEntries:
            false
        }
    }

    private var missingMediaAlertTitle: String {
        switch coordinator.missingMediaNotice {
        case .recoveryRequired:
            "文件缺失"
        case .replacementConfirmationRequired:
            "替换为不同文件？"
        case .none, .noPlayableEntries:
            ""
        }
    }

    private var missingMediaAlertMessage: String {
        switch coordinator.missingMediaNotice {
        case let .recoveryRequired(entryID, _):
            let name = coordinator.playlists.lazy.flatMap(\.entries)
                .first(where: { $0.id == entryID })
                .map { URL(fileURLWithPath: $0.media.lastKnownPath).lastPathComponent }
                ?? "所选文件"
            return "“\(name)”无法定位。可重新定位文件，或仅从 Playlist 移除该条目；取消不会更改任何数据。"
        case let .replacementConfirmationRequired(impact):
            return "所选文件与原文件身份明显不同。确认后会更新共享本地媒体引用，并重置 \(impact.affectedPlaylistCount) 个 Playlist 中 \(impact.affectedEntryCount) 个关联条目的续播位置、已播完状态及音轨和字幕偏好。"
        case .none, .noPlayableEntries:
            return ""
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
            Label("已存储为 \(name)", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
        case let .nameAlreadyExists(name):
            Label("名称“\(name)”已存在，原数据未更改", systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
        case let .failed(message):
            Label(message, systemImage: "xmark.octagon.fill")
                .foregroundStyle(.red)
        }
    }

    @ViewBuilder
    private var missingMediaStatus: some View {
        if case let .noPlayableEntries(missingCount) = coordinator.missingMediaNotice {
            Label(
                "没有可播放条目；已跳过 \(missingCount) 个文件缺失条目",
                systemImage: "exclamationmark.triangle.fill"
            )
            .foregroundStyle(.orange)
        }
    }
}
