import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers

// Real image files for the photo tests, made with CoreGraphics and read back with ImageIO.

/// A new, empty folder in the temporary directory. Remove it at the end of the test.
func makeTemporaryFolder() throws -> URL {
    let folder = FileManager.default.temporaryDirectory
        .appending(path: "WinstonCoreTests-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    return folder
}

/// A solid red image of `width` by `height` stored pixels, encoded as `type`. `orientation` is
/// the EXIF orientation stored with it, as a camera does when the phone is held sideways.
func imageData(width: Int, height: Int, type: UTType = .png, orientation: Int? = nil) throws -> Data {
    let context = try #require(CGContext(
        data: nil,
        width: width,
        height: height,
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ))
    context.setFillColor(red: 1, green: 0, blue: 0, alpha: 1)
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    let image = try #require(context.makeImage())
    let data = NSMutableData()
    let destination = try #require(CGImageDestinationCreateWithData(
        data as CFMutableData,
        type.identifier as CFString,
        1,
        nil
    ))
    let properties = orientation.map { [kCGImagePropertyOrientation: $0] as CFDictionary }
    CGImageDestinationAddImage(destination, image, properties)
    try #require(CGImageDestinationFinalize(destination))
    return data as Data
}

/// What ImageIO reads from an image file.
struct ImageFileInfo: Equatable {
    /// The file's type identifier, such as "public.jpeg".
    var type: String
    /// The stored pixel size, before any orientation is applied.
    var width: Int
    var height: Int
    /// The EXIF orientation a viewer must still apply, or nil when there is none: no
    /// orientation stored, or 1, which is upright.
    var orientation: Int?
}

func imageFileInfo(at url: URL) throws -> ImageFileInfo {
    let source = try #require(CGImageSourceCreateWithURL(url as CFURL, nil))
    let type = try #require(CGImageSourceGetType(source) as String?)
    let properties = try #require(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
    let orientation = properties[kCGImagePropertyOrientation] as? Int
    return ImageFileInfo(
        type: type,
        width: try #require(properties[kCGImagePropertyPixelWidth] as? Int),
        height: try #require(properties[kCGImagePropertyPixelHeight] as? Int),
        orientation: orientation == 1 ? nil : orientation
    )
}
