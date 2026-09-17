import Foundation

/// How a captured page is cleaned up for display and export.
enum EnhancementMode: String, Codable, CaseIterable, Identifiable, Sendable {
    case original
    case document
    case whiteboard
    case photo

    var id: String { rawValue }

    var label: String {
        switch self {
        case .original: return "Original"
        case .document: return "Document"
        case .whiteboard: return "Whiteboard"
        case .photo: return "Photo"
        }
    }

    var systemImage: String {
        switch self {
        case .original: return "photo"
        case .document: return "doc.text"
        case .whiteboard: return "rectangle.on.rectangle"
        case .photo: return "camera.filters"
        }
    }
}

/// One recognized chunk of text with its position on the page.
/// Coordinates are normalized 0...1 with the origin at the BOTTOM-LEFT (Vision's convention).
struct TextBlock: Codable, Hashable, Sendable {
    var text: String
    var x: Double
    var y: Double
    var width: Double
    var height: Double
}

struct ScanPage: Identifiable, Codable, Hashable, Sendable {
    var id: UUID = UUID()
    /// File name (not a full path) of the captured JPEG inside the document folder.
    var imageFile: String
    /// File name of the small preview JPEG inside the document folder.
    var thumbnailFile: String
    var mode: EnhancementMode = .original
    var recognizedText: String = ""
    var textBlocks: [TextBlock] = []

    var hasText: Bool { !recognizedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
}

struct ScanDocument: Identifiable, Codable, Hashable, Sendable {
    var id: UUID = UUID()
    var title: String
    var createdAt: Date = Date()
    var pages: [ScanPage] = []

    var pageCountLabel: String {
        pages.count == 1 ? "1 page" : "\(pages.count) pages"
    }

    /// All recognized text, joined page by page.
    var fullText: String {
        pages.map(\.recognizedText).joined(separator: "\n\n")
    }
}
