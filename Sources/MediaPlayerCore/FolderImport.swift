import Foundation

public struct FolderImportFile: Equatable, Sendable {
    public let url: URL
    public let relativePath: String

    public init(url: URL, relativePath: String) {
        self.url = url
        self.relativePath = relativePath
    }
}

public protocol FolderTraversing: Sendable {
    func files(in folder: URL) async throws -> [FolderImportFile]
}

public enum FolderMediaProbeResult: Equatable, Sendable {
    case supported(LocalMedia)
    case unsupported
    case failed
}

public enum FolderImportDuplicatePolicy: Equatable, Sendable {
    case skipExisting
    case allowDuplicates
}

public struct FolderImportReport: Equatable, Sendable {
    public let addedCount: Int
    public let skippedCount: Int
    public let failedCount: Int

    public init(addedCount: Int, skippedCount: Int, failedCount: Int) {
        self.addedCount = addedCount
        self.skippedCount = skippedCount
        self.failedCount = failedCount
    }
}

public protocol FolderMediaProbing: Sendable {
    func probe(_ file: FolderImportFile) async throws -> FolderMediaProbeResult
}

public struct FileSystemLocalMediaFactory: Sendable {
    public init() {}

    public func media(for url: URL) -> LocalMedia {
        let bookmark = try? url.bookmarkData(
            options: [.withSecurityScope, .securityScopeAllowOnlyReadAccess],
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )
        let fileIdentity = try? url.resourceValues(
            forKeys: [.fileResourceIdentifierKey]
        ).fileResourceIdentifier.flatMap { identifier in
            try NSKeyedArchiver.archivedData(
                withRootObject: identifier,
                requiringSecureCoding: false
            )
        }.map(LocalFileIdentity.init(rawValue:))
        return LocalMedia(
            url: url,
            bookmark: bookmark,
            fileIdentity: fileIdentity
        )
    }
}

public struct FileSystemFolderTraverser: FolderTraversing {
    public init() {}

    public func files(in folder: URL) async throws -> [FolderImportFile] {
        var files: [FolderImportFile] = []
        try collectFiles(in: folder, relativeDirectoryPath: "", into: &files)
        return files.sorted(by: folderImportNaturalLessThan)
    }

    private func collectFiles(
        in directory: URL,
        relativeDirectoryPath: String,
        into files: inout [FolderImportFile]
    ) throws {
        try Task.checkCancellation()
        let children = try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey, .isPackageKey],
            options: .skipsHiddenFiles
        )
        for child in children {
            try Task.checkCancellation()
            let values = try child.resourceValues(
                forKeys: [.isDirectoryKey, .isRegularFileKey, .isPackageKey]
            )
            if values.isPackage == true {
                continue
            }
            let relativePath = relativeDirectoryPath.isEmpty
                ? child.lastPathComponent
                : relativeDirectoryPath + "/" + child.lastPathComponent
            if values.isDirectory == true {
                try collectFiles(
                    in: child,
                    relativeDirectoryPath: relativePath,
                    into: &files
                )
            } else if values.isRegularFile == true {
                files.append(FolderImportFile(url: child, relativePath: relativePath))
            }
        }
    }
}

func folderImportNaturalLessThan(_ lhs: FolderImportFile, _ rhs: FolderImportFile) -> Bool {
    let locale = Locale(identifier: "en_US_POSIX")
    let left = lhs.relativePath.folding(
        options: [.caseInsensitive, .diacriticInsensitive],
        locale: locale
    )
    let right = rhs.relativePath.folding(
        options: [.caseInsensitive, .diacriticInsensitive],
        locale: locale
    )
    let comparison = left.compare(right, options: .numeric)
    if comparison != .orderedSame {
        return comparison == .orderedAscending
    }
    return lhs.relativePath.compare(rhs.relativePath, options: .literal) == .orderedAscending
}

public struct FileSystemFolderMediaProbe: FolderMediaProbing {
    public init() {}

    public func probe(_ file: FolderImportFile) async throws -> FolderMediaProbeResult {
        try Task.checkCancellation()
        guard MVPSelectableMediaFormats.allows(
            filenameExtension: file.url.pathExtension
        ) else {
            return .unsupported
        }
        let header: Data
        do {
            let handle = try FileHandle(forReadingFrom: file.url)
            defer { try? handle.close() }
            header = try handle.read(upToCount: 12) ?? Data()
        } catch {
            return .failed
        }
        guard MVPSelectableMediaFormats.matchesContainerSignature(
            header,
            filenameExtension: file.url.pathExtension.lowercased()
        ) else {
            return .unsupported
        }
        let media = FileSystemLocalMediaFactory().media(for: file.url)
        return media.bookmark == nil ? .failed : .supported(media)
    }
}
