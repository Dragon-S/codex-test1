import Foundation
import SwiftUI

struct PlaybackControlsView: View {
    @ObservedObject var coordinator: PlaybackCoordinator
    let openMedia: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Button("打开…", action: openMedia)
                .keyboardShortcut("o")
            Button("播放") {
                Task { await coordinator.play() }
            }
            Button("暂停") {
                Task { await coordinator.pause() }
            }
            Button("停止") {
                Task { await coordinator.stop() }
            }
            Button("上一首") {
                Task { await coordinator.previous() }
            }
            Button("下一首") {
                Task { await coordinator.next() }
            }
            Spacer()
            Text(statusText)
                .foregroundStyle(.secondary)
                .accessibilityLabel("播放状态")
                .accessibilityValue(statusText)
        }
        .buttonStyle(.bordered)
        .padding(12)
        .background(.ultraThinMaterial)
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
            "删除正在使用的 Playlist？",
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
            if coordinator.detachedNowPlayingEntry != nil {
                Label("当前媒体已脱离 Playlist", systemImage: "link.badge.plus")
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 12)
                    .accessibilityLabel("当前媒体是脱离列表的播放项")
            }
            List(Array(playlist.entries.enumerated()), id: \.element.id) { index, entry in
                HStack {
                    Image(systemName: isPlaying(entry.id, in: playlist.id) ? "play.fill" : "circle")
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
                .accessibilityValue(isPlaying(entry.id, in: playlist.id) ? "当前播放" : "")
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
}
