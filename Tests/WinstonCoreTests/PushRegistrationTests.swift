import Foundation
import Testing
import TelegramLinkTestSupport
import VoiceLoopTestSupport
import WinstonCore

@Suite(.timeLimit(.minutes(1)))
@MainActor
struct PushRegistrationTests {
    @Test func tokenBeforeLoginWaitsForAuthorization() async throws {
        let harness = Harness(fake: FakeTDLib(isLoggedIn: false))
        let push = harness.model.pushRegistration
        push.receivedDeviceToken(Data([0x00, 0x0a, 0xff]), isSandbox: true)
        #expect(push.status == .waitingForLogin)
        #expect(registrations(harness.fake).isEmpty)
        harness.model.start()
        #expect(await eventually { harness.model.authState == .needsPhoneNumber })
        try await harness.model.submitPhoneNumber("+15555550100")
        try await harness.model.submitCode("12345")
        #expect(await eventually { push.status == .registered })
        #expect(registrations(harness.fake) == [
            .registerDevice(token: "000aff", isSandbox: true, otherUserIDs: []),
        ])
    }

    @Test func tokenAfterLoginRegistersInProduction() async {
        let harness = Harness()
        #expect(await harness.startAndLoadChats())
        harness.model.pushRegistration.receivedDeviceToken(Data([0xab]), isSandbox: false)
        #expect(await eventually { harness.model.pushRegistration.status == .registered })
        #expect(registrations(harness.fake) == [
            .registerDevice(token: "ab", isSandbox: false, otherUserIDs: []),
        ])
    }

    @Test func tokenRotationWaitsForEarlierRegistration() async throws {
        let harness = Harness()
        #expect(await harness.startAndLoadChats())
        harness.fake.hold(.registerDevice)
        let push = harness.model.pushRegistration
        push.receivedDeviceToken(Data([1]), isSandbox: true)
        #expect(await eventually { harness.fake.isWaiting(on: .registerDevice) })
        push.receivedDeviceToken(Data([2]), isSandbox: true)
        try await settle()
        #expect(registrations(harness.fake).count == 1)
        harness.fake.release(.registerDevice)
        #expect(await eventually { push.status == .registered })
        #expect(registrations(harness.fake) == [
            .registerDevice(token: "01", isSandbox: true, otherUserIDs: []),
            .registerDevice(token: "02", isSandbox: true, otherUserIDs: []),
        ])
    }

    @Test func failureRetriesOnNextAppleRegistration() async {
        let harness = Harness()
        #expect(await harness.startAndLoadChats())
        let push = harness.model.pushRegistration
        harness.fake.fail(.registerDevice, code: 500, message: "network unavailable")
        push.receivedDeviceToken(Data([1]), isSandbox: true)
        #expect(await eventually { push.status == .failed })
        harness.fake.succeed(.registerDevice)
        push.receivedDeviceToken(Data([1]), isSandbox: true)
        #expect(await eventually { push.status == .registered })
        #expect(registrations(harness.fake).count == 2)
    }

    @Test func logoutDuringRegistrationDoesNotPublishStaleSuccessAndNextLoginRegistersAgain() async throws {
        let harness = Harness()
        #expect(await harness.startAndLoadChats())
        let push = harness.model.pushRegistration
        harness.fake.hold(.registerDevice)
        push.receivedDeviceToken(Data([1]), isSandbox: true)
        #expect(await eventually { harness.fake.isWaiting(on: .registerDevice) })
        await harness.model.logOut()
        #expect(await eventually { harness.model.authState == .needsPhoneNumber })
        harness.fake.release(.registerDevice)
        try await settle()
        #expect(push.status == .waitingForLogin)
        try await harness.model.submitPhoneNumber("+15555550100")
        try await harness.model.submitCode("12345")
        #expect(await eventually { push.status == .registered })
        #expect(registrations(harness.fake).count == 2)
    }

    @Test func appleFailureInvalidatesInFlightResult() async throws {
        let harness = Harness()
        #expect(await harness.startAndLoadChats())
        let push = harness.model.pushRegistration
        harness.fake.hold(.registerDevice)
        push.receivedDeviceToken(Data([1]), isSandbox: true)
        #expect(await eventually { harness.fake.isWaiting(on: .registerDevice) })
        push.registrationFailed()
        harness.fake.release(.registerDevice)
        try await settle()
        #expect(push.status == .failed)
        push.receivedDeviceToken(Data([2]), isSandbox: true)
        #expect(await eventually { push.status == .registered })
    }

    @Test func appleFailureBeforeLoginRemainsVisibleUntilAppleSuppliesAToken() async {
        let harness = Harness()
        let push = harness.model.pushRegistration
        push.registrationFailed()
        #expect(await harness.startAndLoadChats())
        #expect(push.status == .failed)
        push.receivedDeviceToken(Data([1]), isSandbox: true)
        #expect(await eventually { push.status == .registered })
    }

    private func registrations(_ fake: FakeTDLib) -> [FakeTDLib.Request] {
        fake.requests.filter { if case .registerDevice = $0 { true } else { false } }
    }
}
