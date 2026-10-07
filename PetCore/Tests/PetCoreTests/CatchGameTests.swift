import Foundation
import Testing
@testable import PetCore

struct CatchGameTests {
    private func item(_ kind: CatchGame.Kind, x: Double, y: Double) -> CatchGame.Item {
        CatchGame.Item(kind: kind, emoji: kind.emojis[0], x: x, y: y, speed: 300)
    }

    @Test func steeringRunsTheFriendAndStopsAtTheEdges() {
        var rng = SeededGenerator(seed: 1)
        var game = CatchGame(width: 1000, height: 800)
        _ = game.step(dt: 0.1, steer: 1, using: &rng)
        #expect(game.friendX == 590)
        for _ in 0..<20 { _ = game.step(dt: 0.1, steer: 1, using: &rng) }
        #expect(game.friendX == 1000 - CatchGame.friendSize / 2)
        for _ in 0..<40 { _ = game.step(dt: 0.1, steer: -1, using: &rng) }
        #expect(game.friendX == CatchGame.friendSize / 2)
    }

    @Test func tiltHasADeadZoneAndTopsOut() {
        #expect(CatchGame.steer(degrees: 3) == 0)
        #expect(CatchGame.steer(degrees: -3.9) == 0)
        #expect(CatchGame.steer(degrees: 17) == 0.5)
        #expect(CatchGame.steer(degrees: -17) == -0.5)
        #expect(CatchGame.steer(degrees: 60) == 1)
        #expect(CatchGame.steer(degrees: -90) == -1)
    }

    @Test func turningRightSteersRightHoweverItsHeld() {
        let tip = 20.0 * .pi / 180
        // Portrait upright: gravity down the phone (-y); turning the wheel right drops the right edge (+x).
        let portrait = CatchGame.tiltAxis(calibrated: (0, -1, 0))
        #expect(abs(CatchGame.tiltDegrees(gravity: (sin(tip), -cos(tip), 0), axis: portrait) - 20) < 0.001)
        #expect(abs(CatchGame.tiltDegrees(gravity: (0, -1, 0), axis: portrait)) < 0.001, "the calibrated hold is level")
        // Landscape, top to the left: gravity along -x; the user's right is the phone's bottom (-y).
        let landscape = CatchGame.tiltAxis(calibrated: (-1, 0, 0))
        #expect(abs(CatchGame.tiltDegrees(gravity: (-cos(tip), -sin(tip), 0), axis: landscape) - 20) < 0.001)
        // Flat on the palm: tip the right edge down.
        let flat = CatchGame.tiltAxis(calibrated: (0.02, 0.01, -1))
        #expect(abs(CatchGame.tiltDegrees(gravity: (sin(tip), 0, -cos(tip)), axis: flat) - 20) < 0.001)
        #expect(CatchGame.tiltDegrees(gravity: (-sin(tip), 0, -cos(tip)), axis: flat) < 0)
    }

    @Test func catchingFoodScoresAndMeatScoresTwo() {
        var rng = SeededGenerator(seed: 2)
        var game = CatchGame(width: 1000, height: 800)
        let line = 800 - CatchGame.friendSize
        game.items = [item(.fruit, x: 500, y: line - 1), item(.meat, x: 510, y: line - 2), item(.vegetable, x: 900, y: line - 1)]
        let events = game.step(dt: 0.02, steer: 0, using: &rng)
        #expect(events == [.caught(.fruit, points: 1, x: 500), .caught(.meat, points: 2, x: 510)])
        #expect(game.score == 3)
        #expect(game.items.contains { $0.x == 900 }, "missed food keeps falling past the friend")
    }

    @Test func theThirdBombEndsTheGame() {
        var rng = SeededGenerator(seed: 3)
        var game = CatchGame(width: 1000, height: 800)
        let line = 800 - CatchGame.friendSize
        for round in 1...3 {
            game.items = [item(.bomb, x: 500, y: line - 1)]
            let events = game.step(dt: 0.02, steer: 0, using: &rng)
            #expect(events.first == .bomb(x: 500))
            #expect(game.lives == 3 - round)
            #expect(events.contains(.over) == (round == 3))
        }
        #expect(game.isOver)
        #expect(game.step(dt: 1, steer: 1, using: &rng).isEmpty, "nothing moves after game over")
    }

    @Test func itGetsHarderOverTime() {
        #expect(CatchGame.spawnInterval(at: 0) > CatchGame.spawnInterval(at: 60))
        #expect(CatchGame.spawnInterval(at: 600) == 0.35)
        #expect(CatchGame.fallSpeed(at: 0) < CatchGame.fallSpeed(at: 60))
        #expect(CatchGame.fallSpeed(at: 600) == 600)
        #expect(CatchGame.bombChance(at: 0) < CatchGame.bombChance(at: 60))
    }

    @Test func theSameSeedPlaysTheSameGame() {
        func play(_ seed: UInt64) -> [CatchGame.Item] {
            var rng = SeededGenerator(seed: seed)
            var game = CatchGame(width: 1200, height: 900)
            for _ in 0..<300 { _ = game.step(dt: 1.0 / 60, steer: 0.3, using: &rng) }
            return game.items
        }
        #expect(!play(7).isEmpty)
        #expect(play(7) == play(7))
        #expect(play(7) != play(8))
        #expect(play(7).allSatisfy { $0.x >= CatchGame.itemSize / 2 && $0.x <= 1200 - CatchGame.itemSize / 2 })
    }

    @Test func messagesRoundTrip() throws {
        let messages: [CatchMessage] = [.start(.catchFood), .start(.rhythm, rhythm: RhythmPick(song: "sunny", difficulty: .hard, calibration: 0.1)),
                                        .lane(RhythmTouch(lane: 2, down: true, at: 12.5)), .ping(3), .pong(sent: 3, mac: 9), .clicks([1, 2]), .songs(RhythmSongInfo.builtIn), .input(steer: -0.25, jump: true), .pause, .resume, .quit, .hit(.bomb),
                                        .state(CatchStatus(score: 12, lives: 2, best: 30, paused: false, over: false)),
                                        .link(CatchLink(hosts: ["192.168.1.5"], port: 50123, key: Data([1, 2, 3])))]
        for message in messages {
            let data = try JSONEncoder().encode(message)
            #expect(try JSONDecoder().decode(CatchMessage.self, from: data) == message)
            #expect((try? JSONDecoder().decode(PresencePeer.Message.self, from: data)) == nil, "never read as a claim")
        }
    }

    @Test func fastLanePacketsNeedTheKey() {
        let key = Data(repeating: 7, count: 16)
        let input = CatchLink.input(from: CatchLink.packet(-0.4, jump: true, key: key), key: key)
        #expect(input?.steer == -0.4 && input?.jump == true && input?.drop == false)
        #expect(CatchLink.input(from: CatchLink.packet(0, jump: false, drop: true, key: key), key: key)?.drop == true)
        #expect(CatchLink.input(from: CatchLink.packet(3, jump: false, key: key), key: key)?.steer == 1, "clamped")
        #expect(CatchLink.input(from: CatchLink.packet(0.4, jump: false, key: Data(repeating: 8, count: 16)), key: key) == nil)
        #expect(CatchLink.input(from: CatchLink.packet(.nan, jump: false, key: key), key: key) == nil)
        #expect(CatchLink.input(from: Data([1, 2]), key: key) == nil)
    }

    @Test(.timeLimit(.minutes(1))) @MainActor func fastLaneCarriesTiltOverTheNetwork() async throws {
        try #require(!CatchLink.localAddresses().isEmpty, "needs Wi-Fi or Ethernet")
        let listener = CatchLinkListener()
        let sender = CatchLinkSender()
        defer { listener.stop(); sender.stop() }
        let steer = await withCheckedContinuation { (done: CheckedContinuation<Double, Never>) in
            listener.onInput = { steer, _, _ in
                listener.onInput = { _, _, _ in }
                done.resume(returning: steer)
            }
            listener.start { link in
                sender.connect(link)
                Task { for _ in 0..<20 { sender.send(steer: -0.6, jump: false, drop: false); try? await Task.sleep(for: .milliseconds(50)) } }
            }
        }
        #expect(steer == -0.6)
    }
}
