import Foundation

final class LocalizationBundleToken: NSObject {}

struct AppLocalization: Sendable {
    static let live = AppLocalization()

    let languageIdentifier: String
    let locale: Locale
    private let bundlePath: String

    init(
        languageIdentifier: String? = nil,
        locale: Locale = .autoupdatingCurrent,
        bundle: Bundle = Bundle(for: LocalizationBundleToken.self),
        applicationLanguages: [String]? = UserDefaults.standard.stringArray(
            forKey: "AppleLanguages"
        )
    ) {
        let requestedLanguage = languageIdentifier
            ?? applicationLanguages?.first
            ?? bundle.preferredLocalizations.first
            ?? "en"
        self.languageIdentifier = Self.supportedLanguage(for: requestedLanguage)
        self.locale = locale
        bundlePath = bundle.bundlePath
    }

    func text(_ key: String) -> String {
        localizedBundle.localizedString(forKey: key, value: key, table: "Localizable")
    }

    func format(_ key: String, _ arguments: CVarArg...) -> String {
        String(format: text(key), locale: formattingLocale, arguments: arguments)
    }

    func integer(_ value: Int) -> String {
        value.formatted(.number.locale(formattingLocale))
    }

    func decimal(_ value: Double) -> String {
        value.formatted(.number.precision(.fractionLength(0...2)).locale(formattingLocale))
    }

    func playbackRate(_ value: Double) -> String {
        format("playback.rate", decimal(value))
    }

    func dateTime(_ date: Date, timeZone: TimeZone = .autoupdatingCurrent) -> String {
        let formatter = DateFormatter()
        formatter.locale = formattingLocale
        formatter.timeZone = timeZone
        formatter.dateStyle = .short
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }

    func mediaDuration(_ value: TimeInterval) -> String {
        let seconds = max(0, Int(value.rounded(.down)))
        let hours = seconds / 3_600
        let minutes = (seconds % 3_600) / 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, seconds % 60)
        }
        return String(format: "%d:%02d", minutes, seconds % 60)
    }

    func list(_ values: [String]) -> String {
        let formatter = ListFormatter()
        formatter.locale = formattingLocale
        return formatter.string(from: values) ?? values.joined(separator: ", ")
    }

    private var localizedBundle: Bundle {
        let bundle = Bundle(path: bundlePath) ?? .main
        guard let path = bundle.path(forResource: languageIdentifier, ofType: "lproj"),
              let localized = Bundle(path: path) else {
            return bundle
        }
        return localized
    }

    private var formattingLocale: Locale {
        var components = Locale.Components(locale: locale)
        var languageComponents = components.languageComponents
        let appLanguage = Locale.Language.Components(identifier: languageIdentifier)
        languageComponents.languageCode = appLanguage.languageCode
        languageComponents.script = appLanguage.script
        components.languageComponents = languageComponents
        return Locale(components: components)
    }

    private static func supportedLanguage(for identifier: String) -> String {
        let normalized = identifier.lowercased().replacingOccurrences(of: "_", with: "-")
        if normalized == "zh" || normalized.hasPrefix("zh-hans") || normalized.hasPrefix("zh-cn") {
            return "zh-Hans"
        }
        return "en"
    }
}

extension AppLocalization: MediaPlayerMessageLocalizing {
    func playlistNameEmpty() -> String { text("error.playlistNameEmpty") }
    func noNowPlayingListToSave() -> String { text("error.noNowPlayingListToSave") }
    func cannotPersistReadOnlyAccess(fileName: String) -> String {
        format("error.persistReadOnlyAccess", fileName)
    }
    func cannotSwitchTrack(displayName: String) -> String {
        format("error.switchTrack", displayName)
    }
    func noExternalSubtitleToRelocate() -> String { text("error.noSubtitleToRelocate") }
    func cannotPersistExternalSubtitleAccess() -> String { text("error.persistSubtitleAccess") }
    func cannotDisableSubtitles() -> String { text("error.disableSubtitles") }
    func audioTrackFallback(displayName: String) -> String {
        format("notice.audioFallback", displayName)
    }
    func noAudioTrackFallback() -> String { text("notice.noAudioFallback") }
    func subtitlesOff() -> String { text("subtitle.turnOff") }
    func subtitleFallback(displayName: String) -> String {
        format("notice.subtitleFallback", displayName)
    }
    func cannotRestoreSubtitlesOff() -> String { text("error.restoreSubtitleOff") }
    func cannotSaveEntryPreference() -> String { text("error.saveEntryPreference") }
    func cannotSaveSubtitleRelocation() -> String { text("error.saveSubtitleRelocation") }
    func audioTrackDisplayName(_ option: AudioTrackOption) -> String {
        option.displayName(fallback: format("track.defaultName", option.ordinal))
    }
    func subtitleTrackDisplayName(_ option: EmbeddedSubtitleTrackOption) -> String {
        option.displayName(fallback: format("subtitle.defaultName", option.ordinal))
    }
    func cannotOpenDatabase() -> String { text("error.openDatabase") }
    func databaseUnavailable() -> String { text("error.databaseUnavailable") }
    func corruptPersistentState() -> String { text("error.corruptPersistentState") }
    func cannotEncodePersistentState() -> String { text("error.encodePersistentState") }
    func playlistEntryNotFound() -> String { text("error.playlistEntryNotFound") }
    func unexpectedPersistenceError() -> String { text("error.unexpectedPersistence") }
}
