import Foundation
import Testing
@testable import PetCore

struct TriggerEventRecordTests {
    @Test func mapsTriggers() {
        let at = Date(timeIntervalSince1970: 1_789_070_148)
        let app = TriggerEventRecord(trigger: .appSwitched(name: "Final\nCut"), at: at)
        #expect(app.kind == .appSwitched && app.appName == "Final Cut" && app.seconds == nil)
        let idle = TriggerEventRecord(trigger: .wentIdle(seconds: 299.6), at: at)
        #expect(idle.kind == .wentIdle && idle.appName == nil && idle.seconds == 300)
        #expect(TriggerEventRecord(trigger: .poked, at: at).seconds == nil)
    }

    @Test func encodesForTheBackend() throws {
        let record = TriggerEventRecord(trigger: .appSwitched(name: "Xcode"), at: Date(timeIntervalSince1970: 0), id: UUID(uuidString: "00000000-0000-4000-8000-000000000001")!)
        let json = try #require(try JSONSerialization.jsonObject(with: Wire.encoder.encode(record)) as? [String: Any])
        #expect(json["kind"] as? String == "app_switched")
        #expect(json["app_name"] as? String == "Xcode")
        #expect(json["client_event_id"] as? String == "00000000-0000-4000-8000-000000000001")
        #expect(json["occurred_at"] as? String == "1970-01-01T00:00:00Z")
    }
}

extension APIClientTests {
    private func makeUploader() -> (TriggerLogUploader, URL) {
        let url = FileManager.default.temporaryDirectory.appending(path: "trigger-\(UUID()).json")
        return (TriggerLogUploader(api: client, fileURL: url), url)
    }

    @Test func uploaderSkipsExcludedAndPaused() {
        let (uploader, url) = makeUploader()
        defer { try? FileManager.default.removeItem(at: url) }
        uploader.settings = SyncSettings(logSyncPaused: false, excludedApps: ["secret diary"])
        uploader.record(.appSwitched(name: "Secret Diary"))
        uploader.record(.appSwitched(name: "Notes"))
        #expect(uploader.queue.map(\.appName) == ["Notes"])
        uploader.record(.pomodoro(.breakEnded))
        #expect(uploader.queue.count == 1, "pomodoro moments stay on the device")

        uploader.settings.logSyncPaused = true
        uploader.record(.poked)
        #expect(uploader.queue.count == 1)

        // The queue survives a relaunch.
        #expect(TriggerLogUploader(api: client, fileURL: url).queue == uploader.queue)
    }

    @Test func uploaderCapsTheQueue() {
        let (uploader, url) = makeUploader()
        defer { try? FileManager.default.removeItem(at: url) }
        StubServer.shared.reset { _ in (500, "") } // threshold flushes fail and keep everything
        uploader.queue = (0..<TriggerLogUploader.maxQueued).map { TriggerEventRecord(trigger: .wentIdle(seconds: Double($0)), at: .now) }
        for i in 0..<10 {
            uploader.record(.wentIdle(seconds: Double(TriggerLogUploader.maxQueued + i)))
        }
        #expect(uploader.queue.count == TriggerLogUploader.maxQueued)
        #expect(uploader.queue.first?.seconds == 10) // the oldest ten were dropped
        #expect(uploader.queue.last?.seconds == TriggerLogUploader.maxQueued + 9)
    }

    @Test func flushRemovesOnlyAcceptedBatches() async {
        let (uploader, url) = makeUploader()
        defer { try? FileManager.default.removeItem(at: url) }
        StubServer.shared.reset { _ in (503, "") }
        for _ in 0..<(TriggerLogUploader.batchSize + 5) { uploader.record(.poked) }
        await uploader.flush()
        #expect(uploader.queue.count == TriggerLogUploader.batchSize + 5)

        StubServer.shared.reset { request in
            request.url!.path == "/api/trigger-events" ? (200, #"{"data":{"accepted":1}}"#) : (500, "")
        }
        await uploader.flush()
        #expect(uploader.queue.isEmpty)
        #expect(StubServer.shared.count(path: "/api/trigger-events") == 2)
    }

    @Test func flushDropsBatchesTheServerRejects() async {
        let (uploader, url) = makeUploader()
        defer { try? FileManager.default.removeItem(at: url) }
        uploader.record(.poked)
        StubServer.shared.reset { _ in (422, #"{"code":"VALIDATION_FAILED","message":"Validation failed"}"#) }
        await uploader.flush()
        #expect(uploader.queue.isEmpty)
    }

    @Test func claimPairingSavesTheSessionOnce() async throws {
        storage.clear()
        StubServer.shared.reset { _ in (202, #"{"data":{"status":"pending"}}"#) }
        #expect(try await client.claimPairing(code: "ABCDEFGH", pollSecret: "s") == .pending)
        #expect(!client.isSignedIn)

        StubServer.shared.reset { _ in (200, Self.renewed) }
        #expect(try await client.claimPairing(code: "ABCDEFGH", pollSecret: "s") == .signedIn)
        #expect(storage.tokens?.accessToken == "new")

        StubServer.shared.reset { _ in (410, #"{"code":"PAIRING_GONE","message":"Pairing code expired"}"#) }
        await #expect(throws: APIError.server(status: 410, code: "PAIRING_GONE", message: "Pairing code expired")) {
            try await client.claimPairing(code: "ABCDEFGH", pollSecret: "s")
        }
    }

    @Test func pairingInfoRejectsOddCodesWithoutARequest() async throws {
        StubServer.shared.reset { _ in (200, #"{"data":{"device_name":"Mac","expires_at":"2026-09-11T10:00:00Z"}}"#) }
        #expect(try await client.pairingInfo(code: "../me") == nil)
        #expect(StubServer.shared.count(path: "/api/me") == 0)
        #expect(try await client.pairingInfo(code: "ABCD-EFGH")?.deviceName == "Mac")
    }
}
