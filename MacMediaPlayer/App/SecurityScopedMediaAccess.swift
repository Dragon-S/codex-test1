import Foundation

enum SecurityScopedMediaAccessError: Error, LocalizedError {
    case bookmarkCannotBeResolved(String)
    case permissionDenied(String)

    var errorDescription: String? {
        switch self {
        case let .bookmarkCannotBeResolved(path):
            "无法恢复本地媒体引用：\(path)"
        case let .permissionDenied(path):
            "没有读取本地媒体的权限：\(path)"
        }
    }
}

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
            throw SecurityScopedMediaAccessError.bookmarkCannotBeResolved(lastKnownPath)
        }
        let startedSecurityScope = url.startAccessingSecurityScopedResource()
        guard startedSecurityScope || FileManager.default.isReadableFile(atPath: url.path) else {
            throw SecurityScopedMediaAccessError.permissionDenied(url.path)
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
