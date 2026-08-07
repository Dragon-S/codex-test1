import Foundation

public protocol MediaPlayerMessageLocalizing: Sendable {
    func playlistNameEmpty() -> String
    func noNowPlayingListToSave() -> String
    func cannotPersistReadOnlyAccess(fileName: String) -> String
    func cannotSwitchTrack(displayName: String) -> String
    func noExternalSubtitleToRelocate() -> String
    func cannotPersistExternalSubtitleAccess() -> String
    func cannotDisableSubtitles() -> String
    func audioTrackFallback(displayName: String) -> String
    func noAudioTrackFallback() -> String
    func subtitlesOff() -> String
    func subtitleFallback(displayName: String) -> String
    func cannotRestoreSubtitlesOff() -> String
    func cannotSaveEntryPreference() -> String
    func cannotSaveSubtitleRelocation() -> String
    func audioTrackDisplayName(_ option: AudioTrackOption) -> String
    func subtitleTrackDisplayName(_ option: EmbeddedSubtitleTrackOption) -> String
    func cannotOpenDatabase() -> String
    func databaseUnavailable() -> String
    func corruptPersistentState() -> String
    func cannotEncodePersistentState() -> String
    func playlistEntryNotFound() -> String
    func unexpectedPersistenceError() -> String
}

public struct SimplifiedChineseMediaPlayerMessages: MediaPlayerMessageLocalizing {
    public init() {}

    public func playlistNameEmpty() -> String { "Playlist 名称不能为空" }
    public func noNowPlayingListToSave() -> String { "没有可存储的正在播放列表" }
    public func cannotPersistReadOnlyAccess(fileName: String) -> String {
        "无法持久保存 \(fileName) 的只读访问权限"
    }
    public func cannotSwitchTrack(displayName: String) -> String { "无法切换到 \(displayName)" }
    public func noExternalSubtitleToRelocate() -> String { "没有可重新定位的外部字幕" }
    public func cannotPersistExternalSubtitleAccess() -> String {
        "无法持久保存外部字幕的只读访问权限"
    }
    public func cannotDisableSubtitles() -> String { "无法停用字幕" }
    public func audioTrackFallback(displayName: String) -> String {
        "原音轨不可用，已改用 \(displayName)"
    }
    public func noAudioTrackFallback() -> String { "原音轨不可用，且没有可用回退音轨" }
    public func subtitlesOff() -> String { "关闭字幕" }
    public func subtitleFallback(displayName: String) -> String {
        "原字幕不可用，已改用 \(displayName)"
    }
    public func cannotRestoreSubtitlesOff() -> String { "无法恢复关闭字幕偏好" }
    public func cannotSaveEntryPreference() -> String {
        "选择已应用，但条目偏好未能保存"
    }
    public func cannotSaveSubtitleRelocation() -> String {
        "字幕已切换，但重新定位未能保存"
    }
    public func audioTrackDisplayName(_ option: AudioTrackOption) -> String {
        option.displayName(fallback: "音轨 \(option.ordinal)")
    }
    public func subtitleTrackDisplayName(_ option: EmbeddedSubtitleTrackOption) -> String {
        option.displayName(fallback: "字幕 \(option.ordinal)")
    }
    public func cannotOpenDatabase() -> String { "无法打开数据库" }
    public func databaseUnavailable() -> String { "Playlist 数据库不可用" }
    public func corruptPersistentState() -> String { "持久状态已损坏" }
    public func cannotEncodePersistentState() -> String { "无法编码持久状态" }
    public func playlistEntryNotFound() -> String { "找不到要更新的播放列表条目" }
    public func unexpectedPersistenceError() -> String { "无法保存 Playlist 数据" }
}
