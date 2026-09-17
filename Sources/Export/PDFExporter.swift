import UIKit
import PDFKit

/// Builds a searchable PDF: the enhanced page image, with the recognized text drawn
/// invisibly on top of it in the right places. The page looks like a scan but
/// Spotlight, Preview and any PDF reader can select and search the text.
enum PDFExporter {

    struct Page {
        var image: UIImage
        var blocks: [TextBlock]
    }

    /// Assumed resolution of a captured page. A 1700x2200px scan at 200dpi lands
    /// on a 612x792pt page, which is US Letter.
    private static let assumedDPI: CGFloat = 200

    static func makePDF(pages: [Page], title: String) throws -> URL {
        guard !pages.isEmpty else {
            throw NSError(domain: "LensScan.PDFExporter", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "Nothing to export."])
        }

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(sanitize(title)).pdf")
        try? FileManager.default.removeItem(at: url)

        let format = UIGraphicsPDFRendererFormat()
        format.documentInfo = [
            kCGPDFContextTitle as String: title,
            kCGPDFContextCreator as String: "LensScan"
        ]

        let defaultBounds = CGRect(x: 0, y: 0, width: 612, height: 792)
        let renderer = UIGraphicsPDFRenderer(bounds: defaultBounds, format: format)

        try renderer.writePDF(to: url) { context in
            for page in pages {
                let size = pageSize(for: page.image)
                let bounds = CGRect(origin: .zero, size: size)
                context.beginPage(withBounds: bounds, pageInfo: [:])
                page.image.draw(in: bounds)
                drawInvisibleText(page.blocks, in: size)
            }
        }

        return url
    }

    static func makeTextFile(text: String, title: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(sanitize(title)).txt")
        try? FileManager.default.removeItem(at: url)
        try text.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    // MARK: - Internals

    private static func pageSize(for image: UIImage) -> CGSize {
        let pixelWidth = image.size.width * image.scale
        let pixelHeight = image.size.height * image.scale
        guard pixelWidth > 0, pixelHeight > 0 else { return CGSize(width: 612, height: 792) }
        return CGSize(width: pixelWidth * 72 / assumedDPI,
                      height: pixelHeight * 72 / assumedDPI)
    }

    /// Vision reports normalized boxes with the origin at the bottom-left.
    /// The PDF context UIKit hands us is top-left, so flip Y on the way in.
    private static func drawInvisibleText(_ blocks: [TextBlock], in size: CGSize) {
        for block in blocks {
            let trimmed = block.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }

            let rect = CGRect(x: CGFloat(block.x) * size.width,
                              y: (1 - CGFloat(block.y) - CGFloat(block.height)) * size.height,
                              width: CGFloat(block.width) * size.width,
                              height: CGFloat(block.height) * size.height)
            guard rect.width > 1, rect.height > 1 else { continue }

            // Start from the box height, then shrink so the line roughly spans the box
            // width. Getting this close keeps selection highlights lined up with the ink.
            var fontSize = rect.height * 0.85
            let probe = UIFont.systemFont(ofSize: fontSize)
            let measured = (trimmed as NSString).size(withAttributes: [.font: probe])
            if measured.width > 0 {
                fontSize *= min(1.0, rect.width / measured.width)
            }
            fontSize = max(1.0, fontSize)

            let attributes: [NSAttributedString.Key: Any] = [
                .font: UIFont.systemFont(ofSize: fontSize),
                .foregroundColor: UIColor.clear
            ]
            (trimmed as NSString).draw(in: rect, withAttributes: attributes)
        }
    }

    private static func sanitize(_ name: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: " -_"))
        let cleaned = name.unicodeScalars.map { allowed.contains($0) ? Character($0) : "-" }
        let result = String(cleaned).trimmingCharacters(in: .whitespaces)
        return result.isEmpty ? "Scan" : result
    }
}
