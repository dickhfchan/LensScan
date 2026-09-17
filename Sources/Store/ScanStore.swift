import UIKit
import Observation

/// Owns the scan library on disk.
///
/// Layout, all under Application Support/Scans:
///   index.json                       — the document list
///   <documentID>/<pageID>.jpg        — the captured page, corrected but not enhanced
///   <documentID>/<pageID>_thumb.jpg  — a small preview for the library list
///
/// Only the original capture is stored. Enhancement modes are re-rendered on demand,
/// so switching a page from Document to Photo never degrades it and never costs disk.
@MainActor
@Observable
final class ScanStore {
    private(set) var documents: [ScanDocument] = []

    private let root: URL
    private let indexURL: URL
    private let thumbnailMaxDimension: CGFloat = 400

    init() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        self.root = base.appendingPathComponent("Scans", isDirectory: true)
        self.indexURL = root.appendingPathComponent("index.json")
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        load()
    }

    // MARK: - Reading

    func documentFolder(_ documentID: UUID) -> URL {
        root.appendingPathComponent(documentID.uuidString, isDirectory: true)
    }

    func imageURL(for page: ScanPage, in documentID: UUID) -> URL {
        documentFolder(documentID).appendingPathComponent(page.imageFile)
    }

    func thumbnailURL(for page: ScanPage, in documentID: UUID) -> URL {
        documentFolder(documentID).appendingPathComponent(page.thumbnailFile)
    }

    func loadImage(for page: ScanPage, in documentID: UUID) -> UIImage? {
        UIImage(contentsOfFile: imageURL(for: page, in: documentID).path)
    }

    func loadThumbnail(for page: ScanPage, in documentID: UUID) -> UIImage? {
        UIImage(contentsOfFile: thumbnailURL(for: page, in: documentID).path)
    }

    func document(withID id: UUID) -> ScanDocument? {
        documents.first { $0.id == id }
    }

    // MARK: - Writing

    /// Saves a freshly captured batch of pages and kicks off OCR in the background.
    @discardableResult
    func addDocument(images: [UIImage], mode: EnhancementMode = .document) async -> ScanDocument? {
        guard !images.isEmpty else { return nil }

        var document = ScanDocument(title: Self.defaultTitle(), pages: [])
        let folder = documentFolder(document.id)
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        } catch {
            NSLog("Could not create scan folder: \(error.localizedDescription)")
            return nil
        }

        // JPEG encoding of several full-resolution pages is slow enough to drop frames,
        // so keep it off the main actor.
        let maxDimension = thumbnailMaxDimension
        document.pages = await Task.detached(priority: .userInitiated) { () -> [ScanPage] in
            Self.writePages(images, to: folder, mode: mode, thumbnailMaxDimension: maxDimension)
        }.value

        guard !document.pages.isEmpty else { return nil }

        documents.insert(document, at: 0)
        save()

        await runOCR(for: document.id)
        return self.document(withID: document.id) ?? document
    }

    /// Recognizes text on every page that doesn't have any yet.
    func runOCR(for documentID: UUID) async {
        guard let document = document(withID: documentID) else { return }

        for page in document.pages where page.textBlocks.isEmpty {
            guard let image = loadImage(for: page, in: documentID) else { continue }
            let result = await OCRService.recognize(in: image)
            guard !result.blocks.isEmpty else { continue }
            update(pageID: page.id, in: documentID) { page in
                page.recognizedText = result.text
                page.textBlocks = result.blocks
            }
        }
        save()
    }

    func setMode(_ mode: EnhancementMode, forPage pageID: UUID, in documentID: UUID) {
        update(pageID: pageID, in: documentID) { $0.mode = mode }
        save()
    }

    func setMode(_ mode: EnhancementMode, forAllPagesIn documentID: UUID) {
        guard let index = documents.firstIndex(where: { $0.id == documentID }) else { return }
        for pageIndex in documents[index].pages.indices {
            documents[index].pages[pageIndex].mode = mode
        }
        save()
    }

    func rename(_ documentID: UUID, to title: String) {
        guard let index = documents.firstIndex(where: { $0.id == documentID }) else { return }
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        documents[index].title = trimmed.isEmpty ? Self.defaultTitle() : trimmed
        save()
    }

    func delete(_ documentID: UUID) {
        guard let index = documents.firstIndex(where: { $0.id == documentID }) else { return }
        documents.remove(at: index)
        try? FileManager.default.removeItem(at: documentFolder(documentID))
        save()
    }

    func deletePage(_ pageID: UUID, in documentID: UUID) {
        guard let docIndex = documents.firstIndex(where: { $0.id == documentID }),
              let pageIndex = documents[docIndex].pages.firstIndex(where: { $0.id == pageID })
        else { return }

        let page = documents[docIndex].pages[pageIndex]
        try? FileManager.default.removeItem(at: imageURL(for: page, in: documentID))
        try? FileManager.default.removeItem(at: thumbnailURL(for: page, in: documentID))
        documents[docIndex].pages.remove(at: pageIndex)

        if documents[docIndex].pages.isEmpty {
            delete(documentID)
        } else {
            save()
        }
    }

    // MARK: - Persistence

    private func update(pageID: UUID, in documentID: UUID, _ mutate: (inout ScanPage) -> Void) {
        guard let docIndex = documents.firstIndex(where: { $0.id == documentID }),
              let pageIndex = documents[docIndex].pages.firstIndex(where: { $0.id == pageID })
        else { return }
        mutate(&documents[docIndex].pages[pageIndex])
    }

    private func load() {
        guard let data = try? Data(contentsOf: indexURL) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        do {
            documents = try decoder.decode([ScanDocument].self, from: data)
        } catch {
            NSLog("Could not read scan index: \(error.localizedDescription)")
        }
    }

    private func save() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = .prettyPrinted
        do {
            let data = try encoder.encode(documents)
            try data.write(to: indexURL, options: .atomic)
        } catch {
            NSLog("Could not write scan index: \(error.localizedDescription)")
        }
    }

    // MARK: - Helpers

    /// Encodes and writes one JPEG plus one thumbnail per captured image.
    /// Runs off the main actor; touches nothing but the file system.
    nonisolated private static func writePages(_ images: [UIImage],
                                               to folder: URL,
                                               mode: EnhancementMode,
                                               thumbnailMaxDimension: CGFloat) -> [ScanPage] {
        var pages: [ScanPage] = []
        pages.reserveCapacity(images.count)

        for image in images {
            let upright = ImageEnhancer.normalizedOrientation(image)
            let pageID = UUID()
            let imageFile = "\(pageID.uuidString).jpg"
            let thumbFile = "\(pageID.uuidString)_thumb.jpg"

            guard let data = upright.jpegData(compressionQuality: 0.9) else { continue }
            do {
                try data.write(to: folder.appendingPathComponent(imageFile), options: .atomic)
            } catch {
                NSLog("Could not write page: \(error.localizedDescription)")
                continue
            }

            let thumbnail = Self.thumbnail(from: upright, maxDimension: thumbnailMaxDimension)
            if let thumbData = thumbnail.jpegData(compressionQuality: 0.7) {
                try? thumbData.write(to: folder.appendingPathComponent(thumbFile), options: .atomic)
            }

            pages.append(ScanPage(id: pageID,
                                  imageFile: imageFile,
                                  thumbnailFile: thumbFile,
                                  mode: mode))
        }

        return pages
    }

    nonisolated private static func defaultTitle() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return "Scan \(formatter.string(from: Date()))"
    }

    nonisolated private static func thumbnail(from image: UIImage, maxDimension: CGFloat) -> UIImage {
        let longest = max(image.size.width, image.size.height)
        guard longest > maxDimension else { return image }

        let scale = maxDimension / longest
        let size = CGSize(width: image.size.width * scale, height: image.size.height * scale)
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        format.opaque = true
        return UIGraphicsImageRenderer(size: size, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: size))
        }
    }
}
