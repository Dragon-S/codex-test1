import Testing

@testable import MediaPlayerCore

@Suite("媒体选择策略")
struct MediaSelectionPolicyTests {
    @Test("打开面板只允许离线内部 MVP 承诺的核心格式")
    func selectionPolicyExcludesObservationOnlyFormats() {
        for filenameExtension in [
            "mp4", "mov", "mkv", "webm",
            "mp3", "m4a", "aac", "alac", "flac", "wav", "ogg", "opus",
        ] {
            #expect(MVPSelectableMediaFormats.allows(filenameExtension: filenameExtension))
        }

        for filenameExtension in ["avi", "mpeg", "mpg", "ts", "m2ts"] {
            #expect(!MVPSelectableMediaFormats.allows(filenameExtension: filenameExtension))
        }
    }
}
