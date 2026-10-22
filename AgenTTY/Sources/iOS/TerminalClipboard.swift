import Foundation
import ImageIO
import UIKit
import UniformTypeIdentifiers

enum TerminalClipboardImageEncoding: String, Sendable {
    case png
    case jpeg

    var preferredExtension: String {
        rawValue
    }

    static func passthroughEncoding(for contentType: UTType) -> Self? {
        if contentType.conforms(to: .png) {
            return .png
        }
        if contentType.conforms(to: .jpeg) {
            return .jpeg
        }
        return nil
    }
}

struct TerminalClipboardImagePayload: Sendable {
    let data: Data
    let encoding: TerminalClipboardImageEncoding

    var preferredExtension: String {
        encoding.preferredExtension
    }
}

struct TerminalClipboardFilePayload: Sendable {
    let localFileURL: URL
    let contentType: UTType
    let filename: String
    let byteCount: Int

    var preferredExtension: String? {
        let ext = URL(fileURLWithPath: filename).pathExtension
        if !ext.isEmpty {
            return ext
        }
        return contentType.preferredFilenameExtension
    }

    func makeRemotePath() -> String {
        TerminalClipboard.remoteClipboardFilePath(
            filename: filename,
            preferredExtension: preferredExtension
        )
    }
}

enum TerminalClipboardPastePayload: Sendable {
    case images([TerminalClipboardImagePayload])
    case files([any TerminalClipboardItemProvider])
    case text(String)
}

protocol TerminalClipboardPasteboard {
    var hasImages: Bool { get }
    var hasFiles: Bool { get }
    var itemProviders: [any TerminalClipboardItemProvider] { get }
    var hasStrings: Bool { get }
    var string: String? { get }
}

protocol TerminalClipboardItemProvider: Sendable {
    var registeredImageContentTypes: [UTType] { get }
    var registeredContentTypes: [UTType] { get }
    var registeredContentTypesForOpenInPlace: [UTType] { get }
    var suggestedName: String? { get }
    var canLoadUIImage: Bool { get }
    func loadDataRepresentation(for contentType: UTType) async -> Data?
    func loadUIImage() async -> UIImage?
    func loadFileRepresentation(for contentType: UTType) async -> URL?
}

extension TerminalClipboardItemProvider {
    func loadImagePayload() async -> TerminalClipboardImagePayload? {
        await TerminalClipboard.resolveImagePayload(
            registeredImageContentTypes: registeredImageContentTypes,
            loadDataRepresentation: { contentType in
                await loadDataRepresentation(for: contentType)
            },
            canLoadUIImage: canLoadUIImage,
            loadUIImage: {
                await loadUIImage()
            }
        )
    }

    var hasSupportedFileRepresentation: Bool {
        !orderedFileContentTypes.isEmpty
    }

    func loadFilePayload() async -> TerminalClipboardFilePayload? {
        for contentType in orderedFileContentTypes {
            if let ownedFileURL = await loadFileRepresentation(for: contentType) {
                return TerminalClipboard.filePayload(
                    fromOwnedLocalFileURL: ownedFileURL,
                    contentType: contentType,
                    suggestedName: suggestedName
                )
            }
        }

        return nil
    }

    private var orderedFileContentTypes: [UTType] {
        var orderedContentTypes: [UTType] = []
        var seenIdentifiers = Set<String>()

        for contentType in registeredContentTypesForOpenInPlace where TerminalClipboard.isSupportedGenericFileContentType(contentType) {
            if seenIdentifiers.insert(contentType.identifier).inserted {
                orderedContentTypes.append(contentType)
            }
        }

        let hasFilenameHint = !(suggestedName?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
        if hasFilenameHint {
            for contentType in registeredContentTypes where TerminalClipboard.isSupportedGenericFileContentType(contentType) {
                if seenIdentifiers.insert(contentType.identifier).inserted {
                    orderedContentTypes.append(contentType)
                }
            }
        }

        return orderedContentTypes
    }
}

enum TerminalClipboard {
    private static let maximumConcurrentImageProviderLoads = 2
    nonisolated private static let ownedTemporaryDirectoryName = "agentty-clipboard"
    nonisolated private static let normalizedJPEGCompressionQuality: CGFloat = 0.85

    static func hasPasteableGeneralContent() -> Bool {
        hasPasteableContent(pasteboard: SystemTerminalClipboardPasteboard())
    }

    static func hasPasteableContent(
        pasteboard: some TerminalClipboardPasteboard
    ) -> Bool {
        pasteboard.hasImages || pasteboard.hasFiles || pasteboard.hasStrings
    }

    @MainActor
    static func generalPastePayload() async -> TerminalClipboardPastePayload? {
        await generalPastePayload(pasteboard: SystemTerminalClipboardPasteboard())
    }

    static func generalPastePayload(
        pasteboard: some TerminalClipboardPasteboard
    ) async -> TerminalClipboardPastePayload? {
        if pasteboard.hasImages {
            let imagePayloads = await imagePayloads(from: pasteboard.itemProviders)
            if !imagePayloads.isEmpty {
                return .images(imagePayloads)
            }
        }

        if pasteboard.hasFiles {
            let fileProviders = fileItemProviders(from: pasteboard.itemProviders)
            if !fileProviders.isEmpty {
                return .files(fileProviders)
            }
        }

        guard pasteboard.hasStrings, let text = pasteboard.string, !text.isEmpty else {
            return nil
        }
        return .text(text)
    }

    private static func imagePayloads(
        from itemProviders: [any TerminalClipboardItemProvider]
    ) async -> [TerminalClipboardImagePayload] {
        guard !itemProviders.isEmpty else { return [] }

        var orderedPayloads = Array<TerminalClipboardImagePayload?>(repeating: nil, count: itemProviders.count)
        var nextItemProviderIndex = 0

        await withTaskGroup(of: (Int, TerminalClipboardImagePayload?).self) { group in
            let initialLoadCount = min(maximumConcurrentImageProviderLoads, itemProviders.count)

            for _ in 0..<initialLoadCount {
                let index = nextItemProviderIndex
                let itemProvider = itemProviders[index]
                nextItemProviderIndex += 1
                group.addTask {
                    (index, await itemProvider.loadImagePayload())
                }
            }

            for await (index, payload) in group {
                if nextItemProviderIndex < itemProviders.count {
                    let nextIndex = nextItemProviderIndex
                    let itemProvider = itemProviders[nextIndex]
                    nextItemProviderIndex += 1
                    group.addTask {
                        (nextIndex, await itemProvider.loadImagePayload())
                    }
                }
                orderedPayloads[index] = payload
            }
        }

        return orderedPayloads.compactMap { $0 }
    }

    private static func fileItemProviders(
        from itemProviders: [any TerminalClipboardItemProvider]
    ) -> [any TerminalClipboardItemProvider] {
        guard !itemProviders.isEmpty else { return [] }
        return itemProviders.filter(\.hasSupportedFileRepresentation)
    }

    static func resolveImagePayload(
        registeredImageContentTypes: [UTType],
        loadDataRepresentation: @escaping @Sendable (UTType) async -> Data?,
        canLoadUIImage: Bool,
        loadUIImage: @escaping @Sendable () async -> UIImage?
    ) async -> TerminalClipboardImagePayload? {
        guard !Task.isCancelled else { return nil }

        if let payload = await loadCompatiblePassthroughPayload(
            from: registeredImageContentTypes,
            loadDataRepresentation: loadDataRepresentation
        ) {
            return payload
        }

        for contentType in registeredImageContentTypes {
            guard !Task.isCancelled else { return nil }
            guard TerminalClipboardImageEncoding.passthroughEncoding(for: contentType) == nil else { continue }
            guard let data = await loadDataRepresentation(contentType), !data.isEmpty else { continue }
            if let payload = await normalizeUnsupportedImageDataToJPEG(data) {
                return payload
            }
            EsmaLog.terminal.error(
                "clipboard image normalization failed content_type=\(contentType.identifier, privacy: .public)"
            )
        }

        guard canLoadUIImage else { return nil }
        guard let image = await loadUIImage() else { return nil }
        return imagePayload(from: image)
    }

    private static func loadCompatiblePassthroughPayload(
        from contentTypes: [UTType],
        loadDataRepresentation: @escaping @Sendable (UTType) async -> Data?
    ) async -> TerminalClipboardImagePayload? {
        for contentType in contentTypes {
            guard !Task.isCancelled else { return nil }
            guard let encoding = TerminalClipboardImageEncoding.passthroughEncoding(for: contentType) else { continue }
            guard let data = await loadDataRepresentation(contentType), !data.isEmpty else { continue }
            return TerminalClipboardImagePayload(data: data, encoding: encoding)
        }
        return nil
    }

    private static func imagePayload(from image: UIImage) -> TerminalClipboardImagePayload? {
        if let jpegData = image.jpegData(compressionQuality: normalizedJPEGCompressionQuality) {
            return TerminalClipboardImagePayload(data: jpegData, encoding: .jpeg)
        }
        guard let pngData = image.pngData() else {
            EsmaLog.terminal.error("clipboard image paste failed: could not encode UIImage fallback")
            return nil
        }
        return TerminalClipboardImagePayload(data: pngData, encoding: .png)
    }

    @concurrent
    nonisolated private static func normalizeUnsupportedImageDataToJPEG(
        _ data: Data
    ) async -> TerminalClipboardImagePayload? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let imageCount = CGImageSourceGetCount(source)
        guard imageCount > 0 else { return nil }

        let preferredIndex = CGImageSourceGetPrimaryImageIndex(source)
        let imageIndex = (0..<imageCount).contains(preferredIndex) ? preferredIndex : 0

        let destinationData = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            destinationData,
            UTType.jpeg.identifier as CFString,
            1,
            nil
        ) else {
            return nil
        }

        let properties = [kCGImageDestinationLossyCompressionQuality: normalizedJPEGCompressionQuality] as CFDictionary
        CGImageDestinationAddImageFromSource(destination, source, imageIndex, properties)
        guard CGImageDestinationFinalize(destination), destinationData.length > 0 else { return nil }
        return TerminalClipboardImagePayload(data: destinationData as Data, encoding: .jpeg)
    }

    nonisolated static func isSupportedGenericFileContentType(_ contentType: UTType) -> Bool {
        guard contentType.conforms(to: .content) || contentType.conforms(to: .data) else {
            return false
        }
        if contentType.conforms(to: .image) || contentType.conforms(to: .url) {
            return false
        }
        if contentType.conforms(to: .directory) ||
            contentType.conforms(to: .folder) ||
            contentType.conforms(to: .package) ||
            contentType.conforms(to: .bundle) ||
            contentType.conforms(to: .application) ||
            contentType.conforms(to: .symbolicLink) ||
            contentType.conforms(to: .aliasFile) {
            return false
        }
        return true
    }

    nonisolated static func filePayload(
        fromOwnedLocalFileURL localFileURL: URL,
        contentType: UTType,
        suggestedName: String?
    ) -> TerminalClipboardFilePayload? {
        let filename = preferredClipboardFilename(
            suggestedName: suggestedName,
            sourceURL: localFileURL,
            contentType: contentType
        )
        let byteCount = fileByteCount(at: localFileURL)
        return TerminalClipboardFilePayload(
            localFileURL: localFileURL,
            contentType: contentType,
            filename: filename,
            byteCount: byteCount
        )
    }

    nonisolated static func createOwnedTemporaryFileCopy(
        from sourceURL: URL,
        suggestedName: String?,
        contentType: UTType
    ) -> URL? {
        guard let destinationURL = prepareOwnedTemporaryFileURL(
            suggestedName: suggestedName,
            sourceURL: sourceURL,
            contentType: contentType
        ) else {
            return nil
        }

        do {
            if FileManager.default.fileExists(atPath: destinationURL.path(percentEncoded: false)) {
                try FileManager.default.removeItem(at: destinationURL)
            }
            try FileManager.default.copyItem(at: sourceURL, to: destinationURL)
            return destinationURL
        } catch {
            EsmaLog.terminal.error(
                "clipboard file temp copy failed content_type=\(contentType.identifier, privacy: .public) error=\(error.localizedDescription, privacy: .public)"
            )
            return nil
        }
    }

    nonisolated private static func prepareOwnedTemporaryFileURL(
        suggestedName: String?,
        sourceURL: URL?,
        contentType: UTType
    ) -> URL? {
        let fileManager = FileManager.default
        let temporaryDirectory = fileManager.temporaryDirectory.appendingPathComponent(
            ownedTemporaryDirectoryName,
            isDirectory: true
        )

        do {
            try fileManager.createDirectory(
                at: temporaryDirectory,
                withIntermediateDirectories: true
            )
        } catch {
            EsmaLog.terminal.error(
                "clipboard temp directory creation failed error=\(error.localizedDescription, privacy: .public)"
            )
            return nil
        }

        let preferredFilename = preferredClipboardFilename(
            suggestedName: suggestedName,
            sourceURL: sourceURL,
            contentType: contentType
        )

        let pathURL = URL(fileURLWithPath: preferredFilename)
        let basename = pathURL.deletingPathExtension().lastPathComponent
        let ext = pathURL.pathExtension

        var generatedFilename = "agentty-clipboard-\(UUID().uuidString)"
        if !basename.isEmpty {
            generatedFilename += "-\(basename)"
        }
        if !ext.isEmpty {
            generatedFilename += ".\(ext)"
        }

        return temporaryDirectory.appendingPathComponent(generatedFilename, isDirectory: false)
    }

    nonisolated private static func preferredClipboardFilename(
        suggestedName: String?,
        sourceURL: URL?,
        contentType: UTType
    ) -> String {
        let preferredExtension = sanitizedClipboardFilenameExtension(
            from: suggestedName,
            sourceURL: sourceURL,
            contentType: contentType
        )

        if let suggestedName,
            let sanitizedSuggestedName = sanitizedClipboardFilename(suggestedName, preferredExtension: preferredExtension) {
            return sanitizedSuggestedName
        }

        if let sourceURL,
            let sanitizedSourceName = sanitizedClipboardFilename(
                sourceURL.lastPathComponent,
                preferredExtension: preferredExtension
            ) {
            return sanitizedSourceName
        }

        if let preferredExtension {
            return "clipboard.\(preferredExtension)"
        }

        return "clipboard"
    }

    nonisolated private static func sanitizedClipboardFilename(
        _ filename: String,
        preferredExtension: String?
    ) -> String? {
        let sourceURL = URL(fileURLWithPath: filename)
        let basename = sanitizedClipboardFilenameStem(from: sourceURL.deletingPathExtension().lastPathComponent)
        let ext = sanitizedClipboardFilenameExtension(from: filename, sourceURL: nil, contentType: nil) ?? preferredExtension

        if let basename, let ext {
            return "\(basename).\(ext)"
        }
        if let basename {
            return basename
        }
        if let ext {
            return "clipboard.\(ext)"
        }
        return nil
    }

    nonisolated private static func sanitizedClipboardFilenameStem(from basename: String) -> String? {
        let trimmed = basename.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let allowedScalars = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        let sanitized = String(trimmed.unicodeScalars.filter { allowedScalars.contains($0) })
        return sanitized.isEmpty ? nil : sanitized
    }

    nonisolated private static func sanitizedClipboardFilenameExtension(
        from suggestedName: String?,
        sourceURL: URL?,
        contentType: UTType?
    ) -> String? {
        let candidateExtension: String? = {
            if let suggestedName {
                let ext = URL(fileURLWithPath: suggestedName).pathExtension
                if !ext.isEmpty {
                    return ext
                }
            }
            if let sourceURL {
                let ext = sourceURL.pathExtension
                if !ext.isEmpty {
                    return ext
                }
            }
            return contentType?.preferredFilenameExtension
        }()

        return sanitizedClipboardPathExtension(candidateExtension)
    }

    nonisolated private static func sanitizedClipboardPathExtension(
        _ candidateExtension: String?
    ) -> String? {
        guard let candidateExtension, !candidateExtension.isEmpty else { return nil }
        let sanitized = String(candidateExtension.lowercased().unicodeScalars.filter {
            CharacterSet.alphanumerics.contains($0)
        })
        return sanitized.isEmpty ? nil : sanitized
    }

    nonisolated private static func fileByteCount(at url: URL) -> Int {
        let values = try? url.resourceValues(forKeys: [.fileSizeKey])
        return values?.fileSize ?? 0
    }

    nonisolated static func remoteClipboardFilePath(
        filename: String,
        preferredExtension: String?
    ) -> String {
        let filenameURL = URL(fileURLWithPath: filename)
        let stem = sanitizedClipboardFilenameStem(from: filenameURL.deletingPathExtension().lastPathComponent)
        let ext = sanitizedClipboardPathExtension(
            filenameURL.pathExtension.isEmpty ? preferredExtension : filenameURL.pathExtension
        )

        var remoteFilename = "agentty-clipboard-\(UUID().uuidString)"
        if let stem {
            remoteFilename += "-\(stem)"
        }
        if let ext {
            remoteFilename += ".\(ext)"
        }
        return "/tmp/\(remoteFilename)"
    }

    nonisolated static func removeTemporaryFiles(
        for filePayloads: [TerminalClipboardFilePayload]
    ) {
        for filePayload in filePayloads {
            removeTemporaryFile(at: filePayload.localFileURL)
        }
    }

    nonisolated static func removeTemporaryFile(at url: URL) {
        do {
            try FileManager.default.removeItem(at: url)
        } catch {
            guard FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) else { return }
            EsmaLog.terminal.error(
                "clipboard temp file cleanup failed path=\(url.path(percentEncoded: false), privacy: .public) error=\(error.localizedDescription, privacy: .public)"
            )
        }
    }
}

private struct SystemTerminalClipboardPasteboard: TerminalClipboardPasteboard {
    private let pasteboard = UIPasteboard.general

    var hasImages: Bool {
        pasteboard.hasImages
    }

    var hasFiles: Bool {
        itemProviders.contains { $0.hasSupportedFileRepresentation }
    }

    var itemProviders: [any TerminalClipboardItemProvider] {
        pasteboard.itemProviders.map(SystemTerminalClipboardItemProvider.init)
    }

    var hasStrings: Bool {
        pasteboard.hasStrings
    }

    var string: String? {
        pasteboard.string
    }
}

private struct SystemTerminalClipboardItemProvider: TerminalClipboardItemProvider, @unchecked Sendable {
    private let itemProvider: NSItemProvider

    init(itemProvider: NSItemProvider) {
        self.itemProvider = itemProvider
    }

    var registeredImageContentTypes: [UTType] {
        itemProvider.registeredContentTypes(conformingTo: .image)
    }

    var registeredContentTypes: [UTType] {
        itemProvider.registeredContentTypes
    }

    var registeredContentTypesForOpenInPlace: [UTType] {
        itemProvider.registeredContentTypesForOpenInPlace
    }

    var suggestedName: String? {
        itemProvider.suggestedName
    }

    var canLoadUIImage: Bool {
        itemProvider.canLoadObject(ofClass: UIImage.self)
    }

    func loadDataRepresentation(for contentType: UTType) async -> Data? {
        await withCheckedContinuation { continuation in
            _ = itemProvider.loadDataRepresentation(for: contentType) { data, error in
                if let error {
                    EsmaLog.terminal.error(
                        "clipboard image load failed content_type=\(contentType.identifier, privacy: .public) error=\(error.localizedDescription, privacy: .public)"
                    )
                }
                continuation.resume(returning: data)
            }
        }
    }

    func loadUIImage() async -> UIImage? {
        await withCheckedContinuation { continuation in
            _ = itemProvider.loadObject(ofClass: UIImage.self) { image, error in
                if let error {
                    EsmaLog.terminal.error(
                        "clipboard image object fallback failed error=\(error.localizedDescription, privacy: .public)"
                    )
                }
                continuation.resume(returning: image as? UIImage)
            }
        }
    }

    func loadFileRepresentation(for contentType: UTType) async -> URL? {
        let suggestedName = itemProvider.suggestedName
        return await withCheckedContinuation { (continuation: CheckedContinuation<URL?, Never>) in
            _ = itemProvider.loadFileRepresentation(for: contentType, openInPlace: false) { fileURL, _, error in
                if let error {
                    EsmaLog.terminal.error(
                        "clipboard file load failed content_type=\(contentType.identifier, privacy: .public) error=\(error.localizedDescription, privacy: .public)"
                    )
                }

                guard let fileURL else {
                    continuation.resume(returning: nil)
                    return
                }

                let ownedCopyURL = TerminalClipboard.createOwnedTemporaryFileCopy(
                    from: fileURL,
                    suggestedName: suggestedName,
                    contentType: contentType
                )
                continuation.resume(returning: ownedCopyURL)
            }
        }
    }
}
