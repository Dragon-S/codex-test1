import Foundation

public protocol MediaReplacementAssessing: Sendable {
    func isObviousReplacement(
        existing: PersistentLocalMediaReference,
        candidate: LocalMedia
    ) -> Bool
}

public struct DefaultMediaReplacementAssessor: MediaReplacementAssessing {
    public init() {}

    public func isObviousReplacement(
        existing: PersistentLocalMediaReference,
        candidate: LocalMedia
    ) -> Bool {
        if let existingIdentity = existing.fileIdentity,
           let candidateIdentity = candidate.fileIdentity {
            return existingIdentity != candidateIdentity
        }

        let existingExtension = URL(fileURLWithPath: existing.lastKnownPath)
            .pathExtension.lowercased()
        let candidateExtension = candidate.url.pathExtension.lowercased()
        return !existingExtension.isEmpty
            && !candidateExtension.isEmpty
            && existingExtension != candidateExtension
    }
}
