import Foundation
import Testing
@testable import PetCore

extension APIClientTests {
    @Test func presenceSocketRequestIsSignedAfterARefresh() async throws {
        StubServer.shared.reset { request in
            switch (request.url!.path, request.value(forHTTPHeaderField: "Authorization")) {
            case ("/api/auth/refresh", _): (200, Self.renewed)
            case ("/api/presence", "Bearer new"): (200, #"{"data":{"owner":"mac","changed_at":"2026-09-11T10:00:00Z"}}"#)
            default: (401, #"{"code":"UNAUTHORIZED","message":"Unauthorized"}"#)
            }
        }
        let request = try await client.presenceSocketRequest()
        #expect(request.url?.absoluteString == "wss://api.test/api/presence/ws")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer new")
        #expect(request.value(forHTTPHeaderField: "STATIC-API-KEY") == "static")
    }

    @Test func claimDecodesOwner() async throws {
        StubServer.shared.reset { request in
            #expect(request.httpMethod == "POST" && request.url!.path == "/api/presence/claim")
            return (200, #"{"data":{"owner":"phone","changed_at":"2026-09-11T10:00:00.123456Z"}}"#)
        }
        #expect(try await client.claimPresence().owner == .phone)
    }
}

struct PresenceVisibilityTests {
    @Test(arguments: [
        // active, owner, connected, nearby claim → shows
        (true, PresenceOwner.mac, true, false, true),
        (true, PresenceOwner.phone, true, false, false),
        (false, PresenceOwner.mac, true, false, false),   // idle, locked or asleep
        (true, PresenceOwner.mac, true, true, false),     // the iPhone next to it was just opened
        (true, PresenceOwner.phone, false, false, true),  // backend unreachable: keep the friend
        (true, nil as PresenceOwner?, false, false, true),
        (true, nil as PresenceOwner?, false, true, false),
    ])
    func macShowsFriend(active: Bool, owner: PresenceOwner?, connected: Bool, nearby: Bool, shows: Bool) {
        #expect(PresenceVisibility.macShowsFriend(isActive: active, owner: owner, socketConnected: connected, phoneClaimedNearby: nearby) == shows)
    }
}

struct PresencePeerTests {
    /// Sent home, the friend stayed out only until the next presence change (idle and back, wake, a dropped socket).
    @Test func sentHomeStaysHomeWhateverPresenceSays() {
        for socket in [true, false] {
            let presence = PresenceVisibility.macShowsFriend(isActive: true, owner: .mac, socketConnected: socket, phoneClaimedNearby: false)
            #expect(presence)
            #expect(!PresenceVisibility.friendShows(presenceShows: presence, focusHome: false, inGoodbye: false, sentHome: true))
        }
        #expect(!PresenceVisibility.friendShows(presenceShows: true, focusHome: true, inGoodbye: false, sentHome: false))
        #expect(PresenceVisibility.friendShows(presenceShows: true, focusHome: true, inGoodbye: true, sentHome: false), "out for its goodbye line")
        #expect(PresenceVisibility.friendShows(presenceShows: true, focusHome: false, inGoodbye: false, sentHome: false))
        #expect(!PresenceVisibility.friendShows(presenceShows: false, focusHome: false, inGoodbye: false, sentHome: false))
    }

    @Test func accountTagIsStableAndDoesNotRevealTheUserID() {
        let tag = PresencePeer.accountTag(for: "0b8f6c1e-5a1d-4b2f-9f8e-1c2d3e4f5a6b")
        #expect(tag.count == 16)
        #expect(tag == PresencePeer.accountTag(for: "0b8f6c1e-5a1d-4b2f-9f8e-1c2d3e4f5a6b"))
        #expect(tag != PresencePeer.accountTag(for: "another-user"))
        #expect(!tag.contains("0b8f"))
    }
}
