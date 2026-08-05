import Foundation
import Testing
@testable import MediaPlayerCore

@MainActor
@Suite("文件夹导入")
struct FolderImportTests {
    @Test("文件遍历递归忽略隐藏项和应用包，并按相对路径自然排序")
    func traversesVisibleFilesInStableNaturalOrder() async throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }

        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try createFile("Episode 10.mp4", under: root)
        try createFile("Episode 2.mp4", under: root)
        try createFile("notes.txt", under: root)
        try createFile(".hidden.mp4", under: root)
        try createFile("Season 1/Track 1.flac", under: root)
        try createFile(".private/secret.mp4", under: root)
        try createFile("Player.app/Contents/trailer.mp4", under: root)

        let files = try await FileSystemFolderTraverser().files(in: root)

        #expect(files.map(\.relativePath) == [
            "Episode 2.mp4",
            "Episode 10.mp4",
            "notes.txt",
            "Season 1/Track 1.flac",
        ])
    }

    @Test("媒体探测将不支持的文件标记为跳过")
    func probeRejectsUnsupportedFile() async throws {
        let file = FolderImportFile(
            url: URL(fileURLWithPath: "/tmp/readme.txt"),
            relativePath: "readme.txt"
        )

        let result = try await FileSystemFolderMediaProbe().probe(file)

        #expect(result == .unsupported)
    }

    @Test("媒体探测为受支持文件生成可持久化引用和文件身份")
    func probeBuildsPersistentLocalMedia() async throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let url = root.appending(path: "movie.mp4")
        try Data([0x00, 0x00, 0x00, 0x18, 0x66, 0x74, 0x79, 0x70]).write(to: url)

        let result = try await FileSystemFolderMediaProbe().probe(FolderImportFile(
            url: url,
            relativePath: "movie.mp4"
        ))

        guard case let .supported(media) = result else {
            Issue.record("受支持文件本应形成可持久化本地媒体")
            return
        }
        #expect(media.url == url)
        #expect(media.bookmark?.isEmpty == false)
        #expect(media.fileIdentity != nil)
    }

    @Test("媒体探测不会把伪造扩展名的文本形成有效条目")
    func probeRejectsDisguisedTextFile() async throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let url = root.appending(path: "not-a-movie.mp4")
        try Data("这不是媒体".utf8).write(to: url)

        let result = try await FileSystemFolderMediaProbe().probe(FolderImportFile(
            url: url,
            relativePath: "not-a-movie.mp4"
        ))

        #expect(result == .unsupported)
    }

    @Test("媒体探测识别每一种 MVP 文件容器签名")
    func probeRecognizesEveryMVPContainerSignature() async throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let isoBaseMedia = Data([0x00, 0x00, 0x00, 0x18]) + Data("ftyp".utf8)
        let ebml = Data([0x1A, 0x45, 0xDF, 0xA3])
        let signatures: [String: Data] = [
            "mp4": isoBaseMedia,
            "mov": isoBaseMedia,
            "m4a": isoBaseMedia,
            "mkv": ebml,
            "webm": ebml,
            "mp3": Data("ID3".utf8),
            "aac": Data([0xFF, 0xF1]),
            "alac": Data("caff".utf8),
            "flac": Data("fLaC".utf8),
            "wav": Data("RIFF0000WAVE".utf8),
            "ogg": Data("OggS".utf8),
            "opus": Data("OggS".utf8),
        ]
        var rejectedExtensions: [String] = []

        for (filenameExtension, header) in signatures {
            let url = root.appending(path: "sample.\(filenameExtension)")
            try header.write(to: url)
            let result = try await FileSystemFolderMediaProbe().probe(FolderImportFile(
                url: url,
                relativePath: url.lastPathComponent
            ))
            guard case .supported = result else {
                rejectedExtensions.append(filenameExtension)
                continue
            }
        }

        #expect(rejectedExtensions.isEmpty)
    }

    @Test("媒体探测区分 AAC ADTS 与 MP3 帧头")
    func probeDistinguishesAACFromMP3FrameSync() async throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let mp3NamedAAC = root.appending(path: "mpeg-audio.aac")
        let aacNamedMP3 = root.appending(path: "adts.mp3")
        try Data([0xFF, 0xFB, 0x90, 0x64]).write(to: mp3NamedAAC)
        try Data([0xFF, 0xF1, 0x50, 0x80]).write(to: aacNamedMP3)

        let mp3NamedAACResult = try await FileSystemFolderMediaProbe().probe(FolderImportFile(
            url: mp3NamedAAC,
            relativePath: mp3NamedAAC.lastPathComponent
        ))
        let aacNamedMP3Result = try await FileSystemFolderMediaProbe().probe(FolderImportFile(
            url: aacNamedMP3,
            relativePath: aacNamedMP3.lastPathComponent
        ))

        #expect(mp3NamedAACResult == .unsupported)
        #expect(aacNamedMP3Result == .unsupported)
    }

    @Test("批量导入按自然顺序一次提交并报告新增、跳过与失败")
    func importsOneBatchAndReportsEveryOutcome() async throws {
        let coordinator = PlaybackCoordinator(engine: FolderImportFakePlaybackEngine())
        let playlist = try await coordinator.createPlaylist(named: "电视剧")
        let files = ["Episode 10.mp4", "broken.mkv", "notes.txt", "Episode 2.mp4"]
            .map { FolderImportFile(url: URL(fileURLWithPath: "/shows/\($0)"), relativePath: $0) }
        let probe = FolderImportTestProbe(results: [
            "Episode 10.mp4": .supported(importMedia("Episode 10.mp4", identity: 10)),
            "Episode 2.mp4": .supported(importMedia("Episode 2.mp4", identity: 2)),
            "notes.txt": .unsupported,
            "broken.mkv": .failed,
        ])

        let report = try await coordinator.importFolder(
            URL(fileURLWithPath: "/shows"),
            into: playlist.id,
            traverser: FolderImportTestTraverser(files: files),
            mediaProbe: probe
        )

        #expect(report == FolderImportReport(addedCount: 2, skippedCount: 1, failedCount: 1))
        #expect(coordinator.playlists[0].entries.map(\.media.lastKnownPath) == [
            "/shows/Episode 2.mp4",
            "/shows/Episode 10.mp4",
        ])
    }

    @Test("默认按本地媒体身份去重，显式允许时为整批创建独立条目")
    func appliesDuplicatePolicyByLocalMediaIdentity() async throws {
        let coordinator = PlaybackCoordinator(engine: FolderImportFakePlaybackEngine())
        let playlist = try await coordinator.createPlaylist(named: "合集")
        let existing = importMedia("existing.mp4", identity: 1)
        _ = try await coordinator.add(existing, to: playlist.id)
        let files = [
            FolderImportFile(
                url: URL(fileURLWithPath: "/album/moved-existing.mp4"),
                relativePath: "moved-existing.mp4"
            ),
            FolderImportFile(
                url: URL(fileURLWithPath: "/album/new-1.mp4"),
                relativePath: "new-1.mp4"
            ),
            FolderImportFile(
                url: URL(fileURLWithPath: "/album/new-2.mp4"),
                relativePath: "new-2.mp4"
            ),
        ]
        let probe = FolderImportTestProbe(results: [
            "moved-existing.mp4": .supported(importMedia("moved-existing.mp4", identity: 1)),
            "new-1.mp4": .supported(importMedia("new-1.mp4", identity: 2)),
            "new-2.mp4": .supported(importMedia("new-2.mp4", identity: 2)),
        ])
        let traverser = FolderImportTestTraverser(files: files)

        let defaultReport = try await coordinator.importFolder(
            URL(fileURLWithPath: "/album"),
            into: playlist.id,
            traverser: traverser,
            mediaProbe: probe
        )
        let duplicateReport = try await coordinator.importFolder(
            URL(fileURLWithPath: "/album"),
            into: playlist.id,
            duplicatePolicy: .allowDuplicates,
            traverser: traverser,
            mediaProbe: probe
        )

        #expect(defaultReport == FolderImportReport(
            addedCount: 1,
            skippedCount: 2,
            failedCount: 0
        ))
        #expect(duplicateReport == FolderImportReport(
            addedCount: 3,
            skippedCount: 0,
            failedCount: 0
        ))
        let entries = coordinator.playlists[0].entries
        #expect(Set(entries.map(\.id)).count == entries.count)
        #expect(Set(entries.filter { $0.media.fileIdentity == existing.fileIdentity }
            .map(\.media.id)).count == 1)
        #expect(Set(entries.filter {
            $0.media.fileIdentity == LocalFileIdentity(rawValue: Data([0x02]))
        }.map(\.media.lastKnownPath)).count == 1)
    }

    @Test("默认跳过同一文件时刷新共享引用而不新增条目")
    func skippedDuplicateRefreshesSharedReference() async throws {
        let coordinator = PlaybackCoordinator(engine: FolderImportFakePlaybackEngine())
        let playlist = try await coordinator.createPlaylist(named: "移动文件")
        let identity = LocalFileIdentity(rawValue: Data([0x01]))
        let original = LocalMedia(
            url: URL(fileURLWithPath: "/old/movie.mp4"),
            bookmark: Data([0x01]),
            fileIdentity: identity
        )
        _ = try await coordinator.add(original, to: playlist.id)
        let movedFile = FolderImportFile(
            url: URL(fileURLWithPath: "/new/movie.mp4"),
            relativePath: "movie.mp4"
        )
        let movedMedia = LocalMedia(
            url: movedFile.url,
            bookmark: Data([0x02]),
            fileIdentity: identity
        )

        let report = try await coordinator.importFolder(
            URL(fileURLWithPath: "/new"),
            into: playlist.id,
            traverser: FolderImportTestTraverser(files: [movedFile]),
            mediaProbe: FolderImportTestProbe(results: [
                "movie.mp4": .supported(movedMedia),
            ])
        )

        #expect(report == FolderImportReport(
            addedCount: 0,
            skippedCount: 1,
            failedCount: 0
        ))
        let entries = coordinator.playlists[0].entries
        #expect(entries.count == 1)
        #expect(entries[0].media.lastKnownPath == "/new/movie.mp4")
        #expect(entries[0].media.bookmark == Data([0x02]))
    }

    @Test("向其他 Playlist 导入时同步刷新当前播放的共享引用")
    func refreshesActiveProjectionWhenImportingIntoAnotherPlaylist() async throws {
        let coordinator = PlaybackCoordinator(engine: FolderImportFakePlaybackEngine())
        let activePlaylist = try await coordinator.createPlaylist(named: "正在播放")
        let targetPlaylist = try await coordinator.createPlaylist(named: "导入目标")
        let identity = LocalFileIdentity(rawValue: Data([0x01]))
        let current = try await coordinator.add(LocalMedia(
            url: URL(fileURLWithPath: "/old/movie.mp4"),
            bookmark: Data([0x01]),
            fileIdentity: identity
        ), to: activePlaylist.id)
        try await coordinator.playEntry(current.id, in: activePlaylist.id)
        let movedFile = FolderImportFile(
            url: URL(fileURLWithPath: "/new/movie.mp4"),
            relativePath: "movie.mp4"
        )

        _ = try await coordinator.importFolder(
            URL(fileURLWithPath: "/new"),
            into: targetPlaylist.id,
            traverser: FolderImportTestTraverser(files: [movedFile]),
            mediaProbe: FolderImportTestProbe(results: [
                "movie.mp4": .supported(LocalMedia(
                    url: movedFile.url,
                    bookmark: Data([0x02]),
                    fileIdentity: identity
                )),
            ])
        )

        #expect(coordinator.nowPlayingList.currentMedia?.url.path == "/new/movie.mp4")
        #expect(coordinator.nowPlayingList.currentMedia?.bookmark == Data([0x02]))
    }

    @Test("旧引用缺少文件身份时仍按相同标准路径跳过重复媒体")
    func fallsBackToPathWhenExistingIdentityIsMissing() async throws {
        let coordinator = PlaybackCoordinator(engine: FolderImportFakePlaybackEngine())
        let playlist = try await coordinator.createPlaylist(named: "旧引用")
        _ = try await coordinator.add(
            LocalMedia(
                url: URL(fileURLWithPath: "/album/same.mp4"),
                bookmark: Data([0x01])
            ),
            to: playlist.id
        )
        let file = FolderImportFile(
            url: URL(fileURLWithPath: "/album/same.mp4"),
            relativePath: "same.mp4"
        )

        let report = try await coordinator.importFolder(
            URL(fileURLWithPath: "/album"),
            into: playlist.id,
            traverser: FolderImportTestTraverser(files: [file]),
            mediaProbe: FolderImportTestProbe(results: [
                "same.mp4": .supported(LocalMedia(
                    url: URL(fileURLWithPath: "/album/same.mp4"),
                    bookmark: Data([0x09]),
                    fileIdentity: LocalFileIdentity(rawValue: Data([0x09]))
                )),
            ])
        )

        #expect(report == FolderImportReport(
            addedCount: 0,
            skippedCount: 1,
            failedCount: 0
        ))
        #expect(coordinator.playlists[0].entries.count == 1)
    }

    @Test("批量探测发生致命失败时不提交已处理条目")
    func fatalProbeFailureLeavesPlaylistUnchanged() async throws {
        let store = InMemoryPlaylistStore()
        let coordinator = PlaybackCoordinator(
            engine: FolderImportFakePlaybackEngine(),
            playlistStore: store
        )
        let playlist = try await coordinator.createPlaylist(named: "原子导入")
        let files = ["first.mp4", "second.mp4"].map {
            FolderImportFile(url: URL(fileURLWithPath: "/batch/\($0)"), relativePath: $0)
        }

        do {
            _ = try await coordinator.importFolder(
                URL(fileURLWithPath: "/batch"),
                into: playlist.id,
                traverser: FolderImportTestTraverser(files: files),
                mediaProbe: FailingFolderImportProbe()
            )
            Issue.record("致命探测失败本应终止整批导入")
        } catch FolderImportTestError.expected {
        } catch {
            Issue.record("收到意外错误：\(error)")
        }

        #expect(coordinator.playlists[0].entries.isEmpty)
        #expect((await store.loadLibrary()).playlists[0].entries.isEmpty)
    }

    @Test("取消批量导入不会提交已处理条目")
    func cancellationLeavesPlaylistUnchanged() async throws {
        let store = InMemoryPlaylistStore()
        let coordinator = PlaybackCoordinator(
            engine: FolderImportFakePlaybackEngine(),
            playlistStore: store
        )
        let playlist = try await coordinator.createPlaylist(named: "取消导入")
        let files = ["first.mp4", "second.mp4"].map {
            FolderImportFile(url: URL(fileURLWithPath: "/batch/\($0)"), relativePath: $0)
        }
        let probe = PausingFolderImportProbe()
        var reachedSecondProbe = probe.reachedSecondProbe.makeAsyncIterator()
        let task = Task {
            try await coordinator.importFolder(
                URL(fileURLWithPath: "/batch"),
                into: playlist.id,
                traverser: FolderImportTestTraverser(files: files),
                mediaProbe: probe
            )
        }
        _ = await reachedSecondProbe.next()

        task.cancel()
        do {
            _ = try await task.value
            Issue.record("取消本应终止整批导入")
        } catch is CancellationError {
        } catch {
            Issue.record("收到意外错误：\(error)")
        }

        #expect(coordinator.playlists[0].entries.isEmpty)
        #expect((await store.loadLibrary()).playlists[0].entries.isEmpty)
    }

    @Test("导入正在播放的 Playlist 会立即扩展后续条目而不中断当前媒体")
    func updatesActivePlaylistAndRandomRound() async throws {
        let coordinator = PlaybackCoordinator(engine: FolderImportFakePlaybackEngine())
        let playlist = try await coordinator.createPlaylist(named: "当前列表")
        let current = try await coordinator.add(
            importMedia("current.mp4", identity: 1),
            to: playlist.id
        )
        try await coordinator.playEntry(current.id, in: playlist.id)
        try await coordinator.setPlaybackOrder(.random, for: playlist.id)
        let imported = FolderImportFile(
            url: URL(fileURLWithPath: "/album/imported.mp4"),
            relativePath: "imported.mp4"
        )

        _ = try await coordinator.importFolder(
            URL(fileURLWithPath: "/album"),
            into: playlist.id,
            traverser: FolderImportTestTraverser(files: [imported]),
            mediaProbe: FolderImportTestProbe(results: [
                "imported.mp4": .supported(importMedia("imported.mp4", identity: 2)),
            ])
        )

        let updated = coordinator.playlists[0]
        let importedEntry = try #require(updated.entries.last)
        #expect(coordinator.nowPlayingList.entries.map(\.id) == updated.entries.map(\.id))
        let currentIndex = try #require(coordinator.nowPlayingList.currentIndex)
        #expect(coordinator.nowPlayingList.entries[currentIndex].id == current.id)
        #expect(updated.randomRound?.order.contains(importedEntry.id) == true)
        #expect(updated.randomRound?.playedEntryIDs.contains(importedEntry.id) == false)
    }

    private func createFile(_ relativePath: String, under root: URL) throws {
        let url = root.appending(path: relativePath)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data().write(to: url)
    }
}

private struct FolderImportTestTraverser: FolderTraversing {
    let files: [FolderImportFile]

    func files(in folder: URL) async throws -> [FolderImportFile] {
        files
    }
}

private struct FolderImportTestProbe: FolderMediaProbing {
    let results: [String: FolderMediaProbeResult]

    func probe(_ file: FolderImportFile) async throws -> FolderMediaProbeResult {
        results[file.relativePath] ?? .failed
    }
}

private enum FolderImportTestError: Error {
    case expected
}

private struct FailingFolderImportProbe: FolderMediaProbing {
    func probe(_ file: FolderImportFile) async throws -> FolderMediaProbeResult {
        if file.relativePath == "second.mp4" {
            throw FolderImportTestError.expected
        }
        return .supported(importMedia("first.mp4", identity: 1))
    }
}

private actor PausingFolderImportProbe: FolderMediaProbing {
    nonisolated let reachedSecondProbe: AsyncStream<Void>
    private let continuation: AsyncStream<Void>.Continuation
    private var probeCount = 0

    init() {
        (reachedSecondProbe, continuation) = AsyncStream.makeStream()
    }

    func probe(_ file: FolderImportFile) async throws -> FolderMediaProbeResult {
        probeCount += 1
        if probeCount == 1 {
            return .supported(importMedia("first.mp4", identity: 1))
        }
        continuation.yield()
        try await Task.sleep(for: .seconds(60))
        return .failed
    }
}

private actor FolderImportFakePlaybackEngine: PlaybackEngine {
    nonisolated let events: AsyncStream<PlaybackEngineEvent> = AsyncStream { _ in }

    func load(_ media: LocalMedia, loadID: PlaybackLoadID) {}
    func play() {}
    func pause() {}
    func stop() {}
    func seek(to position: TimeInterval) {}
    func setPlaybackRate(_ rate: Double) {}
    func setPlayerVolume(_ volume: Double) {}
    func setMuted(_ isMuted: Bool) {}
}

private func importMedia(_ name: String, identity: UInt8) -> LocalMedia {
    LocalMedia(
        url: URL(fileURLWithPath: "/shows/\(name)"),
        bookmark: Data([identity]),
        fileIdentity: LocalFileIdentity(rawValue: Data([identity]))
    )
}
