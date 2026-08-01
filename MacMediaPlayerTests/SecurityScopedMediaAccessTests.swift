import Foundation
import Testing
@testable import MacMediaPlayer

@Test("安全作用域文件访问可从只读书签恢复本地媒体引用")
func restoresReadOnlySecurityScopedBookmark() async throws {
    let fileURL = FileManager.default.temporaryDirectory
        .appending(path: "bookmark-\(UUID().uuidString).mp4")
    try Data([0x00]).write(to: fileURL)
    defer { try? FileManager.default.removeItem(at: fileURL) }
    let bookmark = try fileURL.bookmarkData(
        options: [.withSecurityScope, .securityScopeAllowOnlyReadAccess],
        includingResourceValuesForKeys: nil,
        relativeTo: nil
    )
    let referenceID = LocalMediaReferenceID()
    let access = SecurityScopedMediaAccess()

    let restored = try await access.restore(PersistentLocalMediaReference(
        id: referenceID,
        bookmark: bookmark,
        lastKnownPath: fileURL.path
    ))

    #expect(restored.referenceID == referenceID)
    #expect(restored.url.standardizedFileURL == fileURL.standardizedFileURL)
    #expect(FileManager.default.isReadableFile(atPath: restored.url.path))
}
