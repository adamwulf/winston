import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Image file work done off the main actor with ImageIO, the same way on iOS and macOS.
public enum PhotoFiles {
    public enum Failure: Error {
        case unreadableImage
        case encodingFailed
    }

    /// Downscales an image to at most 2560 px on its long side, encodes it as JPEG at quality 0.85,
    /// and writes it to a temporary file to pass to `sendPhoto`.
    @concurrent
    public static func jpegForSending(from data: Data) async throws -> URL {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else {
            throw Failure.unreadableImage
        }
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] ?? [:]
        let width = properties[kCGImagePropertyPixelWidth] as? Int ?? 0
        let height = properties[kCGImagePropertyPixelHeight] as? Int ?? 0
        let longSide = max(width, height)
        guard let image = thumbnail(of: source, maxPixelSize: longSide > 0 ? min(longSide, 2560) : 2560) else {
            throw Failure.unreadableImage
        }

        let url = URL.temporaryDirectory.appending(path: "\(UUID().uuidString).jpg")
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil) else {
            throw Failure.encodingFailed
        }
        let options = [kCGImageDestinationLossyCompressionQuality: 0.85] as CFDictionary
        CGImageDestinationAddImage(destination, image, options)
        guard CGImageDestinationFinalize(destination) else {
            throw Failure.encodingFailed
        }
        return url
    }

    /// Decodes an image file at a display size, upright. Nil if the file isn't a readable image.
    @concurrent
    public static func displayImage(at url: URL, maxPixelSize: Int) async -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return thumbnail(of: source, maxPixelSize: maxPixelSize)
    }

    /// A copy of the image no larger than `maxPixelSize` on its long side, with its EXIF orientation applied.
    private static func thumbnail(of source: CGImageSource, maxPixelSize: Int) -> CGImage? {
        let options = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
        ] as CFDictionary
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options)
    }
}
