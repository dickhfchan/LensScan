import UIKit
import CoreImage
import CoreImage.CIFilterBuiltins

/// Stage 4 of the scanning pipeline: make a flat, well-lit "scan" out of a photo.
///
/// The key trick is illumination flattening. Dividing the image by a heavily
/// blurred copy of itself estimates and cancels the local background brightness,
/// which removes the shadow gradient you get from a hand or a desk lamp. Everything
/// after that — contrast, tone curve, sharpening — is much better behaved once the
/// page background is uniformly white.
final class ImageEnhancer {
    static let shared = ImageEnhancer()

    private let context: CIContext
    private let cache = NSCache<NSString, UIImage>()

    private init() {
        self.context = CIContext(options: [.cacheIntermediates: false])
        cache.countLimit = 24
    }

    // MARK: - Public

    func enhance(_ image: UIImage, mode: EnhancementMode, cacheKey: String? = nil) -> UIImage {
        guard mode != .original else { return image }

        if let cacheKey {
            let key = "\(cacheKey)-\(mode.rawValue)" as NSString
            if let cached = cache.object(forKey: key) { return cached }
            let result = render(image, mode: mode)
            cache.setObject(result, forKey: key)
            return result
        }
        return render(image, mode: mode)
    }

    func clearCache() {
        cache.removeAllObjects()
    }

    // MARK: - Pipeline

    private func render(_ image: UIImage, mode: EnhancementMode) -> UIImage {
        let upright = Self.normalizedOrientation(image)
        guard let cgImage = upright.cgImage else { return image }

        let input = CIImage(cgImage: cgImage)
        let extent = input.extent
        guard extent.width > 1, extent.height > 1 else { return image }

        let output: CIImage
        switch mode {
        case .original:
            return image
        case .document:
            output = documentPipeline(input)
        case .whiteboard:
            output = whiteboardPipeline(input)
        case .photo:
            output = photoPipeline(input)
        }

        guard let rendered = context.createCGImage(output.cropped(to: extent), from: extent) else {
            return image
        }
        return UIImage(cgImage: rendered, scale: upright.scale, orientation: .up)
    }

    /// Crisp black-on-white text. Flatten the lighting, drop color, then push the
    /// tone curve so paper goes to true white and ink goes to near black.
    private func documentPipeline(_ input: CIImage) -> CIImage {
        var image = flattenIllumination(input, radiusFraction: 0.05)

        let controls = CIFilter.colorControls()
        controls.inputImage = image
        controls.saturation = 0
        controls.contrast = 1.15
        controls.brightness = 0.0
        image = controls.outputImage ?? image

        let curve = CIFilter.toneCurve()
        curve.inputImage = image
        curve.point0 = CGPoint(x: 0.00, y: 0.00)
        curve.point1 = CGPoint(x: 0.30, y: 0.12)
        curve.point2 = CGPoint(x: 0.55, y: 0.60)
        curve.point3 = CGPoint(x: 0.78, y: 0.96)
        curve.point4 = CGPoint(x: 1.00, y: 1.00)
        image = curve.outputImage ?? image

        return sharpen(image, radiusFraction: 0.0015, intensity: 0.7)
    }

    /// Whiteboards keep their marker colors, so flatten the glare but boost
    /// saturation instead of removing it.
    private func whiteboardPipeline(_ input: CIImage) -> CIImage {
        var image = flattenIllumination(input, radiusFraction: 0.08)

        let controls = CIFilter.colorControls()
        controls.inputImage = image
        controls.saturation = 1.35
        controls.contrast = 1.12
        controls.brightness = 0.02
        image = controls.outputImage ?? image

        let vibrance = CIFilter.vibrance()
        vibrance.inputImage = image
        vibrance.amount = 0.35
        image = vibrance.outputImage ?? image

        return sharpen(image, radiusFraction: 0.0012, intensity: 0.5)
    }

    /// Receipts, photos, book pages with images: keep the tones, just clean them up.
    private func photoPipeline(_ input: CIImage) -> CIImage {
        let controls = CIFilter.colorControls()
        controls.inputImage = input
        controls.saturation = 1.06
        controls.contrast = 1.08
        controls.brightness = 0.01
        let image = controls.outputImage ?? input

        return sharpen(image, radiusFraction: 0.001, intensity: 0.45)
    }

    // MARK: - Building blocks

    /// Divide the image by a blurred copy of itself to cancel uneven lighting.
    /// The blur radius has to be much larger than the text strokes, or the text
    /// itself gets treated as background and washes out.
    private func flattenIllumination(_ input: CIImage, radiusFraction: CGFloat) -> CIImage {
        let extent = input.extent
        let sigma = max(extent.width, extent.height) * radiusFraction
        guard sigma > 1 else { return input }

        let blurred = input
            .clampedToExtent()
            .applyingGaussianBlur(sigma: Double(sigma))
            .cropped(to: extent)

        // CIDivideBlendMode computes background / foreground.
        let divide = CIFilter.divideBlendMode()
        divide.inputImage = blurred      // divisor
        divide.backgroundImage = input   // dividend

        return (divide.outputImage ?? input).cropped(to: extent)
    }

    private func sharpen(_ input: CIImage, radiusFraction: CGFloat, intensity: Float) -> CIImage {
        let extent = input.extent
        let radius = max(1.0, max(extent.width, extent.height) * radiusFraction)

        let unsharp = CIFilter.unsharpMask()
        unsharp.inputImage = input.clampedToExtent()
        unsharp.radius = Float(radius)
        unsharp.intensity = intensity

        return (unsharp.outputImage ?? input).cropped(to: extent)
    }

    /// CIImage ignores UIImage.imageOrientation, so bake any rotation into the pixels first.
    static func normalizedOrientation(_ image: UIImage) -> UIImage {
        guard image.imageOrientation != .up else { return image }
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = image.scale
        format.opaque = true
        return UIGraphicsImageRenderer(size: image.size, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: image.size))
        }
    }
}
