import Foundation

final class SecurityScopedMediaAccess: PersistentMediaAccess, PersistentExternalSubtitleAccess, @unchecked Sendable {
    private let lock = NSLock()
    private var accessedURLs: [URL] = []

    func restore(_ reference: PersistentLocalMediaReference) throws -> LocalMedia {
        let restored = try restoreBookmark(reference.bookmark, lastKnownPath: reference.lastKnownPath)
        return LocalMedia(
            url: restored.url,
            referenceID: reference.id,
            bookmark: restored.bookmark,
            fileIdentity: reference.fileIdentity
        )
    }

    func restore(
        _ reference: PersistentExternalSubtitleReference
    ) throws -> LocalExternalSubtitle {
        let restored = try restoreBookmark(reference.bookmark, lastKnownPath: reference.lastKnownPath)
        return LocalExternalSubtitle(
            url: restored.url,
            bookmark: restored.bookmark
        )
    }

    private func restoreBookmark(
        _ bookmarkData: Data,
        lastKnownPath: String
    ) throws -> (url: URL, bookmark: Data) {
        var isStale = false
        let url: URL
        do {
            url = try URL(
                resolvingBookmarkData: bookmarkData,
                options: [.withSecurityScope, .withoutUI],
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            )
        } catch {
            let error: PersistentMediaAccessError = FileManager.default.fileExists(
                atPath: lastKnownPath
            ) ? .unreadable(lastKnownPath) : .missing(lastKnownPath)
            throw error
        }
        let startedSecurityScope = url.startAccessingSecurityScopedResource()
        guard startedSecurityScope || FileManager.default.isReadableFile(atPath: url.path) else {
            throw PersistentMediaAccessError.unreadable(url.path)
        }
        if startedSecurityScope {
            lock.withLock {
                accessedURLs.append(url)
            }
        }
        let bookmark: Data
        if isStale {
            bookmark = try url.bookmarkData(
                options: [.withSecurityScope, .securityScopeAllowOnlyReadAccess],
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )
        } else {
            bookmark = bookmarkData
        }
        return (url, bookmark)
    }

    deinit {
        let urls = lock.withLock {
            let snapshot = accessedURLs
            accessedURLs.removeAll()
            return snapshot
        }
        for url in urls {
            url.stopAccessingSecurityScopedResource()
        }
    }
}
