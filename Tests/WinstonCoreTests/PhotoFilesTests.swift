import Foundation
import Testing
import UniformTypeIdentifiers
import WinstonCore

/// Re-encoding a picked photo for sending.
@MainActor
@Suite(.timeLimit(.minutes(1)))
struct JPEGForSendingTests {
    @Test func aLargeImageIsScaledDownTo2560PixelsOnItsLongSide() async throws {
        let data = try imageData(width: 4000, height: 2000)

        let jpeg = try await PhotoFiles.jpegForSending(from: data)
        defer { try? FileManager.default.removeItem(at: jpeg) }

        #expect(try imageFileInfo(at: jpeg) == ImageFileInfo(type: UTType.jpeg.identifier, width: 2560, height: 1280))
        #expect(jpeg.deletingLastPathComponent().pathComponents == URL.temporaryDirectory.pathComponents)
    }

    @Test func aSmallImageKeepsItsSize() async throws {
        let data = try imageData(width: 40, height: 30)

        let jpeg = try await PhotoFiles.jpegForSending(from: data)
        defer { try? FileManager.default.removeItem(at: jpeg) }

        #expect(try imageFileInfo(at: jpeg) == ImageFileInfo(type: UTType.jpeg.identifier, width: 40, height: 30))
    }

    @Test func anImageStoredSidewaysComesOutUpright() async throws {
        // Stored 40 by 30, to be shown rotated a quarter turn clockwise (EXIF orientation 6), as
        // a photo taken with the phone held upright.
        let data = try imageData(width: 40, height: 30, type: .jpeg, orientation: 6)

        let jpeg = try await PhotoFiles.jpegForSending(from: data)
        defer { try? FileManager.default.removeItem(at: jpeg) }

        #expect(try imageFileInfo(at: jpeg) == ImageFileInfo(type: UTType.jpeg.identifier, width: 30, height: 40, orientation: nil))
    }

    @Test func dataThatIsNotAnImageIsUnreadable() async throws {
        await #expect(throws: PhotoFiles.Failure.unreadableImage) {
            try await PhotoFiles.jpegForSending(from: Data("not an image".utf8))
        }
    }
}

/// Decoding an image file to show in the chat.
@MainActor
@Suite(.timeLimit(.minutes(1)))
struct DisplayImageTests {
    @Test func aLargeImageIsScaledDownToTheGivenSizeOnItsLongSide() async throws {
        let folder = try makeTemporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appending(path: "wide.png")
        try imageData(width: 400, height: 200).write(to: file)

        let image = try #require(await PhotoFiles.displayImage(at: file, maxPixelSize: 100))

        #expect(image.width == 100)
        #expect(image.height == 50)
    }

    @Test func aFileThatIsNotAnImageGivesNoImage() async throws {
        let folder = try makeTemporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appending(path: "notes.txt")
        try Data("not an image".utf8).write(to: file)

        #expect(await PhotoFiles.displayImage(at: file, maxPixelSize: 100) == nil)
    }

    @Test func aMissingFileGivesNoImage() async throws {
        let folder = try makeTemporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }

        #expect(await PhotoFiles.displayImage(at: folder.appending(path: "gone.png"), maxPixelSize: 100) == nil)
    }
}
