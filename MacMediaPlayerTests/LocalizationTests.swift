import Foundation
import Testing
@testable import MacMediaPlayer

@MainActor
@Suite("应用本地化与区域格式")
struct LocalizationTests {
    @Test("简体中文、英文和不支持语言从同一资源解析且回退英文")
    func resolvesSupportedLanguagesAndFallsBackToEnglish() {
        let chinese = AppLocalization(
            languageIdentifier: "zh-Hans",
            locale: Locale(identifier: "zh_CN")
        )
        let english = AppLocalization(
            languageIdentifier: "en",
            locale: Locale(identifier: "en_US")
        )
        let unsupported = AppLocalization(
            languageIdentifier: "fr",
            locale: Locale(identifier: "fr_FR")
        )

        #expect(chinese.text("menu.file") == "文件")
        #expect(english.text("menu.file") == "File")
        #expect(unsupported.text("menu.file") == "File")
        #expect(
            english.format("accessibility.currentEntry", "夜航.mp4", 2, 12)
                == "Current Playlist entry: 夜航.mp4, entry 2 of 12"
        )
        #expect(english.format("playlist.savedAs", "夜航 Playlist") == "Saved as 夜航 Playlist")
    }

    @Test("数量与日期时间遵循区域而媒体时长保持无歧义")
    func appliesRegionalFormatsWithoutAmbiguousMediaDuration() throws {
        let date = try #require(
            ISO8601DateFormatter().date(from: "2026-01-02T15:04:00Z")
        )
        let unitedStates = AppLocalization(
            languageIdentifier: "en",
            locale: Locale(identifier: "en_US")
        )
        let germany = AppLocalization(
            languageIdentifier: "en",
            locale: Locale(identifier: "de_DE")
        )
        let englishInChina = AppLocalization(
            languageIdentifier: "en",
            locale: Locale(identifier: "zh_CN")
        )
        let unitedStatesWithTwentyFourHourClock = AppLocalization(
            languageIdentifier: "en",
            locale: Locale(identifier: "en_US@hours=h23")
        )

        #expect(unitedStates.integer(1_234) == "1,234")
        #expect(germany.integer(1_234) == "1.234")
        #expect(germany.playbackRate(1.25) == "1,25×")
        #expect(germany.list(["Title", "Artist", "Album"]) == "Title, Artist, and Album")
        #expect(unitedStates.dateTime(date, timeZone: .gmt) == "1/2/26, 3:04 PM")
        #expect(germany.dateTime(date, timeZone: .gmt) == "02.01.26, 15:04")
        #expect(englishInChina.dateTime(date, timeZone: .gmt) == "2026/1/2, 15:04")
        #expect(
            unitedStatesWithTwentyFourHourClock.dateTime(date, timeZone: .gmt)
                == "1/2/26, 15:04"
        )
        #expect(unitedStates.mediaDuration(3_723) == "1:02:03")
        #expect(germany.mediaDuration(3_723) == "1:02:03")
    }

    @Test("英文设置选择器按最长标题与选项保留完整宽度")
    func englishSettingsPickersReserveEnoughWidth() {
        let english = AppLocalization(
            languageIdentifier: "en",
            locale: Locale(identifier: "en_US")
        )

        #expect(PlaybackControlsLayout.seekStepPickerWidth(localization: english) > 100)
        #expect(PlaybackControlsLayout.speedPickerWidth(localization: english) >= 105)
        #expect(
            PlaybackControlsLayout.pickerRowMinimumWidth(localization: english)
                <= PlaybackControlsLayout.compactContentWidth
        )
    }

    @Test("中英文资源键完全对应并覆盖核心路径、错误与辅助功能文案")
    func localizationResourcesRemainAuditableAndInSync() throws {
        let english = try resourceEntries(languageIdentifier: "en")
        let chinese = try resourceEntries(languageIdentifier: "zh-Hans")

        #expect(Set(english.keys) == Set(chinese.keys))
        #expect(english.count >= 185)
        #expect(english["播放"] == "Play")
        #expect(english["missingMedia.title"] == "File Missing")
        #expect(english["accessibility.playbackCanvas"] == "Current media playback area")
        #expect(chinese["播放"] == "播放")
        #expect(chinese["missingMedia.title"] == "文件缺失")
        #expect(chinese["accessibility.playbackCanvas"] == "当前媒体播放区域")
    }

    private func resourceEntries(languageIdentifier: String) throws -> [String: String] {
        let bundle = Bundle(for: LocalizationBundleToken.self)
        let path = try #require(bundle.path(
            forResource: languageIdentifier,
            ofType: "lproj"
        ))
        let data = try Data(contentsOf: URL(fileURLWithPath: path).appending(
            path: "Localizable.strings"
        ))
        return try #require(
            PropertyListSerialization.propertyList(from: data, format: nil)
                as? [String: String]
        )
    }
}
