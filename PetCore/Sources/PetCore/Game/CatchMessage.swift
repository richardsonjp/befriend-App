//
//  CatchMessage.swift
//  PetCore
//
//  What the iPhone controller and the Mac games (Catch M41, Runner M42) say to each other over the nearby peer.
//

import Foundation

public nonisolated enum CatchMessage: Codable, Equatable, Sendable {
    // iPhone → Mac
    case start(MacGame)
    case input(steer: Double, jump: Bool) // steer -1…1; jump while the pad is held
    case pause
    case resume
    case quit
    // Mac → iPhone
    case state(CatchStatus)
    case hit(CatchHit)
    case link(CatchLink) // where to send tilt over the fast lane
}

public nonisolated enum MacGame: String, Codable, Sendable, CaseIterable {
    case catchFood = "catch"
    case runner

    public var title: String { self == .catchFood ? "Catch" : "Runner" }
}

public nonisolated struct CatchStatus: Codable, Equatable, Sendable {
    public var score: Int
    public var lives: Int
    public var best: Int
    public var paused: Bool
    public var over: Bool

    public init(score: Int, lives: Int, best: Int, paused: Bool, over: Bool) {
        self.score = score
        self.lives = lives
        self.best = best
        self.paused = paused
        self.over = over
    }
}

public nonisolated enum CatchHit: String, Codable, Sendable {
    case food
    case bomb
}
