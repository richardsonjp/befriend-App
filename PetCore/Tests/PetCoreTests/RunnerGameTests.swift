import CoreGraphics
import Testing
@testable import PetCore

struct RunnerGameTests {
    /// Three lines of words, 40 points apart, across the middle of a 1000 × 800 screen.
    private let lines: [CGRect] = [400.0, 440, 480].flatMap { y in
        stride(from: 100.0, to: 900, by: 90).map { CGRect(x: $0, y: y, width: 70, height: 18) }
    }

    private func game(words: [CGRect]) -> RunnerGame {
        var game = RunnerGame(width: 1000, height: 800)
        game.setWords(words)
        return game
    }

    private func run(_ game: inout RunnerGame, seconds: Double, steer: Double = 0, jump: Bool = false,
                     drop: Bool = false) -> [RunnerGame.Event] {
        var rng = SeededGenerator(seed: 1)
        var events: [RunnerGame.Event] = []
        for _ in 0..<Int(seconds * 60) { events += game.step(dt: 1.0 / 60, steer: steer, jump: jump, drop: drop, using: &rng) }
        return events
    }

    /// Off the cloud and onto the top line of words.
    private func onTopLine() -> RunnerGame {
        var game = game(words: lines)
        _ = run(&game, seconds: 1, steer: 1)
        _ = run(&game, seconds: 0.5)
        return game
    }

    @Test func wordsAreLedgesAndTheGapsBetweenThemToo() {
        let game = game(words: lines + [CGRect(x: 0, y: 10, width: 300, height: 18), CGRect(x: 0, y: 600, width: 2, height: 18)])
        #expect(game.ledges.filter { !$0.isCloud }.count == lines.count, "no room above a word at the very top; a speck isn't a word")
        #expect(game.ledges.contains { $0.minX == 100 && $0.maxX == 170 && $0.y == 400 })
    }

    @Test func itLandsOnTheFirstWordBelow() {
        let game = onTopLine()
        #expect(game.isStanding && game.y == 400)
    }

    @Test func droppingGoesThroughOneLine() {
        var game = onTopLine()
        _ = run(&game, seconds: 0.5, drop: true)
        #expect(game.isStanding && game.y == 440, "through the line it stood on, onto the next one")
    }

    @Test func aSecondJumpInTheAirGoesHigher() {
        func peak(doubleJump: Bool) -> Double {
            var game = onTopLine()
            var rng = SeededGenerator(seed: 2)
            var top = game.y
            for frame in 0..<60 {
                let jump = frame < 15 || (doubleJump && frame >= 20 && frame < 35) // let go, then press again mid-air
                _ = game.step(dt: 1.0 / 60, steer: 0, jump: jump, using: &rng)
                top = min(top, game.y)
            }
            return 400 - top
        }
        #expect(peak(doubleJump: false) > 80)
        #expect(peak(doubleJump: true) > peak(doubleJump: false) + 60)
    }

    @Test func aWordThatScrollsAwayDropsTheFriend() {
        var game = onTopLine()
        game.setWords(lines.map { $0.offsetBy(dx: 0, dy: 3) })
        #expect(game.isStanding && game.y == 403, "OCR wobble keeps it standing")
        game.setWords([])
        #expect(!game.isStanding)
    }

    @Test func coinsScoreAndLavaBurns() {
        var game = game(words: [])
        let start = (x: game.x, y: game.y)
        game.coins = [.init(x: start.x, y: start.y - 30)]
        #expect(run(&game, seconds: 1.0 / 60).first == .coin(x: start.x, y: start.y - 30))
        #expect(game.score == 1)
        var burns = 0
        for _ in 0..<3 { burns += run(&game, seconds: 1.5, steer: 1).filter { if case .burned = $0 { true } else { false } }.count }
        #expect(burns == 3 && game.isOver)
    }

    @Test func lavaComesInHigherWaves() {
        #expect(abs(RunnerGame.lavaLevel(at: 0) - 0.05) < 0.001)
        #expect(abs(RunnerGame.lavaLevel(at: 20) - 0.2) < 0.001)
        #expect(abs(RunnerGame.lavaLevel(at: 30) - 0.05) < 0.001)
        #expect(RunnerGame.lavaLevel(at: 50) > RunnerGame.lavaLevel(at: 20))
        #expect(1 - RunnerGame.lavaLevel(at: 2000) > 0.32 + 0.1, "the clouds stay above the highest lava")
    }
}
