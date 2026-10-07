import CoreGraphics
import Testing
@testable import PetCore

struct RunnerGameTests {
    private let size = (width: 1000.0, height: 800.0)

    private func game(windows: [RunnerGame.Window] = []) -> RunnerGame {
        var game = RunnerGame(width: size.width, height: size.height)
        game.setWindows(windows)
        return game
    }

    private func run(_ game: inout RunnerGame, seconds: Double, steer: Double = 0, jump: Bool = false) -> [RunnerGame.Event] {
        var rng = SeededGenerator(seed: 1)
        var events: [RunnerGame.Event] = []
        for _ in 0..<Int(seconds * 60) { events += game.step(dt: 1.0 / 60, steer: steer, jump: jump, using: &rng) }
        return events
    }

    @Test func aWindowInFrontCoversTheEdgeBehindIt() {
        let back = RunnerGame.Window(id: 2, frame: CGRect(x: 100, y: 400, width: 600, height: 300))
        let front = RunnerGame.Window(id: 1, frame: CGRect(x: 300, y: 300, width: 200, height: 300))
        let ledges = RunnerGame.ledges(windows: [front, back], width: 1000, height: 800)
        #expect(ledges.map(\.window) == [1, 2, 2])
        #expect(ledges.filter { $0.window == 2 }.map { [$0.minX, $0.maxX] } == [[100, 300], [500, 700]])
        #expect(RunnerGame.ledges(windows: [.init(id: 3, frame: CGRect(x: 0, y: 10, width: 500, height: 100))], width: 1000, height: 800).isEmpty,
                "an edge at the very top leaves no room to stand")
    }

    @Test func itStartsOnTheHighestLedgeAndLandsFromAbove() {
        var game = game(windows: [.init(id: 7, frame: CGRect(x: 100, y: 200, width: 400, height: 300))])
        #expect(game.isStanding)
        _ = run(&game, seconds: 0.2)
        #expect(game.y == RunnerGame.clouds(width: 1000, height: 800)[0].y || game.y == 200)
        // Walk off the right of everything: fall, then land on the lower window from above.
        game = self.game(windows: [.init(id: 7, frame: CGRect(x: 0, y: 500, width: 1000, height: 300))])
        _ = run(&game, seconds: 1, steer: 1)
        #expect(game.isStanding && game.y == 500)
    }

    @Test func holdingJumpGoesHigherThanATap() {
        func peak(holding: Double) -> Double {
            var game = game(windows: [.init(id: 7, frame: CGRect(x: 0, y: 500, width: 1000, height: 300))])
            _ = run(&game, seconds: 1, steer: 1) // off the cloud onto the window
            var rng = SeededGenerator(seed: 2)
            var top = game.y
            for frame in 0..<60 {
                _ = game.step(dt: 1.0 / 60, steer: 0, jump: Double(frame) / 60 < holding, using: &rng)
                top = min(top, game.y)
            }
            return 500 - top
        }
        #expect(peak(holding: 1) > 200)
        #expect(peak(holding: 0.05) < peak(holding: 1) * 0.6)
    }

    @Test func aMovedWindowCarriesTheFriend() {
        var game = game(windows: [.init(id: 7, frame: CGRect(x: 0, y: 500, width: 1000, height: 300))])
        _ = run(&game, seconds: 1, steer: 1)
        let x = game.x
        game.setWindows([.init(id: 7, frame: CGRect(x: -40, y: 450, width: 1000, height: 300))])
        #expect(game.x == x - 40 && game.y == 450 && game.isStanding)
        game.setWindows([])
        #expect(!game.isStanding, "its window closed")
    }

    @Test func coinsScoreAndLavaBurns() {
        var game = game()
        let start = (x: game.x, y: game.y)
        game.coins = [.init(x: start.x, y: start.y - 30)]
        #expect(run(&game, seconds: 1.0 / 60).first == .coin(x: start.x, y: start.y - 30))
        #expect(game.score == 1)
        // Off the cloud into the lava three times.
        var burns = 0
        for _ in 0..<3 { burns += run(&game, seconds: 1.5, steer: 1).filter { if case .burned = $0 { true } else { false } }.count }
        #expect(burns == 3 && game.isOver)
    }

    @Test func lavaComesInHigherWaves() {
        #expect(abs(RunnerGame.lavaLevel(at: 0) - 0.05) < 0.001)
        #expect(abs(RunnerGame.lavaLevel(at: 20) - 0.2) < 0.001)
        #expect(abs(RunnerGame.lavaLevel(at: 30) - 0.05) < 0.001)
        #expect(RunnerGame.lavaLevel(at: 50) > RunnerGame.lavaLevel(at: 20))
        #expect(RunnerGame.lavaLevel(at: 2000) <= 0.55)
        #expect(1 - RunnerGame.lavaLevel(at: 2000) > 0.32 + 0.1, "the clouds stay above the highest lava")
    }
}
