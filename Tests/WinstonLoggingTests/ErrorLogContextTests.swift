import Foundation
import LogSupport
import Testing

@Suite("Error.logContext")
struct ErrorLogContextTests {
    private enum UndescribedError: Error {
        case failed(status: Int32)
    }

    private struct PlainError: Error {}

    @Test
    func enumKeepsTheCaseAndPayloadItsDescriptionDrops() throws {
        let error = UndescribedError.failed(status: -34018)
        #expect(!error.localizedDescription.contains("-34018"))

        let errorCase = try #require(error.logContext()["errorCase"])
        #expect(errorCase.contains("failed(status: -34018)"))
    }

    @Test
    func nsErrorReportsDomainCodeAndUnderlyingWithoutUserInfo() throws {
        let underlying = NSError(domain: NSPOSIXErrorDomain, code: 1)
        let error = NSError(domain: NSCocoaErrorDomain, code: 134092, userInfo: [
            NSUnderlyingErrorKey: underlying,
            NSFilePathErrorKey: "/Users/someone/private-file",
        ])

        let context = error.logContext()

        #expect(context["errorDomain"] == NSCocoaErrorDomain)
        #expect(context["errorCode"] == "134092")
        #expect(context["underlyingDomain"] == NSPOSIXErrorDomain)
        #expect(context["underlyingCode"] == "1")
        #expect(context["errorCase"] == nil)
        #expect(!context.values.contains { $0.contains("private-file") })
    }

    @Test
    func foundationErrorStructIsNotReflected() {
        let error = CocoaError(.fileReadNoSuchFile, userInfo: [NSFilePathErrorKey: "/Users/someone/private-file"])

        let context = error.logContext()

        #expect(context["errorCase"] == nil)
        #expect(context["errorDomain"] == NSCocoaErrorDomain)
        #expect(context["errorCode"] == String(CocoaError.fileReadNoSuchFile.rawValue))
    }

    @Test
    func logCodesLeaveOutTheDescriptionThatNamesAFile() {
        let underlying = NSError(domain: NSPOSIXErrorDomain, code: 2)
        let error = NSError(domain: NSCocoaErrorDomain, code: NSFileReadNoSuchFileError, userInfo: [
            NSUnderlyingErrorKey: underlying,
            NSLocalizedDescriptionKey: "The file “Jane Doe headshot.jpg” couldn’t be opened.",
        ])

        let codes = error.logCodes(["bytes": "12"])

        #expect(codes["bytes"] == "12")
        #expect(codes["errorDomain"] == NSCocoaErrorDomain)
        #expect(codes["errorCode"] == String(NSFileReadNoSuchFileError))
        #expect(codes["underlyingDomain"] == NSPOSIXErrorDomain)
        #expect(codes["underlyingCode"] == "2")
        #expect(!codes.values.contains { $0.contains("Jane Doe") })
    }

    @Test
    func structErrorIsIdentifiedByItsDomain() throws {
        let context = PlainError().logContext()
        #expect(context["errorCase"] == nil)
        let domain = try #require(context["errorDomain"])
        #expect(domain.contains("PlainError"))
    }

    @Test
    func extraFieldsAreKeptAndErrorFieldsWin() {
        let context = PlainError().logContext(["chatID": "42", "errorCode": "caller value"])
        #expect(context["chatID"] == "42")
        #expect(context["errorCode"] != "caller value")
    }

    @Test
    func metadataCarriesTheSameFields() {
        let metadata = UndescribedError.failed(status: 7).logMetadata(["op": "write"])
        #expect(metadata["op"]?.description == "write")
        #expect(metadata["errorCase"]?.description.contains("failed(status: 7)") == true)
    }

    @Test
    func metadataErrorFieldsWinOverExtraWithTheSameKey() {
        let error = NSError(domain: "Test", code: 7, userInfo: [NSLocalizedDescriptionKey: "Disk full."])

        let metadata = error.logMetadata([
            "op": "write",
            "error": "caller error",
            "errorDomain": "caller domain",
            "errorCode": "caller code",
        ])

        #expect(metadata["op"]?.description == "write")
        #expect(metadata["error"]?.description == "Disk full.")
        #expect(metadata["errorDomain"]?.description == "Test")
        #expect(metadata["errorCode"]?.description == "7")
    }
}
