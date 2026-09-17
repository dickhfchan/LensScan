import UIKit
import Vision

struct OCRResult: Sendable {
    var text: String
    var blocks: [TextBlock]

    static let empty = OCRResult(text: "", blocks: [])
}

/// Stage 5: on-device text recognition. Nothing leaves the phone.
enum OCRService {

    /// Languages to try, in priority order. Vision gets noticeably less accurate
    /// the more languages you give it, so keep this list short and relevant.
    /// Values not supported by the current OS revision are dropped automatically.
    static var preferredLanguages: [String] = ["en-US", "zh-Hans"]

    static func recognize(in image: UIImage) async -> OCRResult {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(returning: recognizeSync(in: image))
            }
        }
    }

    static func recognizeSync(in image: UIImage) -> OCRResult {
        let upright = ImageEnhancer.normalizedOrientation(image)
        guard let cgImage = upright.cgImage else { return .empty }

        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        let languages = supportedSubset(of: preferredLanguages)
        if !languages.isEmpty {
            request.recognitionLanguages = languages
        }

        let handler = VNImageRequestHandler(cgImage: cgImage, orientation: .up, options: [:])
        do {
            try handler.perform([request])
        } catch {
            NSLog("OCR failed: \(error.localizedDescription)")
            return .empty
        }

        let observations = request.results ?? []
        var lines: [String] = []
        var blocks: [TextBlock] = []
        lines.reserveCapacity(observations.count)
        blocks.reserveCapacity(observations.count)

        for observation in observations {
            guard let candidate = observation.topCandidates(1).first else { continue }
            let string = candidate.string
            guard !string.isEmpty else { continue }
            lines.append(string)

            let box = observation.boundingBox
            blocks.append(TextBlock(text: string,
                                    x: Double(box.origin.x),
                                    y: Double(box.origin.y),
                                    width: Double(box.width),
                                    height: Double(box.height)))
        }

        return OCRResult(text: lines.joined(separator: "\n"), blocks: blocks)
    }

    private static func supportedSubset(of wanted: [String]) -> [String] {
        let probe = VNRecognizeTextRequest()
        probe.recognitionLevel = .accurate
        let supported = (try? probe.supportedRecognitionLanguages()) ?? []
        guard !supported.isEmpty else { return [] }
        return wanted.filter { supported.contains($0) }
    }
}
