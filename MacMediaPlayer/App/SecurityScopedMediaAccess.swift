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

final class SecurityScopedMediaAccess: PersistentMediaAccess, @unchecked Sendable {
    private let lock = NSLock()
    private var accessedURLs: [URL] = []

    func restore(_ reference: PersistentLocalMediaReference) throws -> LocalMedia {
        var isStale = false
        let url: URL
        do {
            url = try URL(
                resolvingBookmarkData: reference.bookmark,
                options: [.withSecurityScope, .withoutUI],
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            )
        } catch {
            throw SecurityScopedMediaAccessError.bookmarkCannotBeResolved(reference.lastKnownPath)
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
            bookmark = reference.bookmark
        }
        return LocalMedia(url: url, referenceID: reference.id, bookmark: bookmark)
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
