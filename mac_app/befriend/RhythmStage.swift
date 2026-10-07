//
//  RhythmStage.swift
//  befriend
//
//  Rhythm (M43) on the Mac's game layer: a four-lane highway down the middle of the display. Notes fall to the hit
//  line near the bottom; held notes have a tail; a health bar runs beside it. y grows downwards.
//

import PetCore
import SwiftUI

enum RhythmStage {
    static let laneWidth = 72.0
    /// Seconds of notes shown above the hit line.
    static let lookahead = 1.6
    /// The phone's lanes are the same colours, left to right.
    static let colors: [Color] = [.green, .red, .yellow, .blue]

    static func highway(in size: CGSize) -> CGRect {
        let width = laneWidth * Double(RhythmSong.lanes)
        return CGRect(x: size.width / 2 - width / 2, y: 0, width: width, height: size.height)
    }

    static func hitY(in size: CGSize) -> Double { size.height - 150 }

    static func laneX(_ lane: Int, in size: CGSize) -> Double { highway(in: size).minX + laneWidth * (Double(lane) + 0.5) }

    private static func y(_ time: Double, now: Double, in size: CGSize) -> Double {
        hitY(in: size) - (time - now) / lookahead * hitY(in: size)
    }

    static func draw(_ judge: RhythmJudge, at now: Double, in context: GraphicsContext, size: CGSize) {
        let road = highway(in: size), hit = hitY(in: size)
        context.fill(Path(roundedRect: road.insetBy(dx: -8, dy: -20), cornerRadius: 16), with: .color(.black.opacity(0.5)))
        for lane in 1..<RhythmSong.lanes {
            let x = road.minX + laneWidth * Double(lane)
            context.stroke(Path { $0.move(to: CGPoint(x: x, y: 0)); $0.addLine(to: CGPoint(x: x, y: size.height)) },
                           with: .color(.white.opacity(0.12)), lineWidth: 1)
        }
        context.stroke(Path { $0.move(to: CGPoint(x: road.minX, y: hit)); $0.addLine(to: CGPoint(x: road.maxX, y: hit)) },
                       with: .color(.white.opacity(0.8)), lineWidth: 3)
        for lane in 0..<RhythmSong.lanes {
            let ring = CGRect(x: laneX(lane, in: size) - 28, y: hit - 28, width: 56, height: 56)
            context.stroke(Path(ellipseIn: ring), with: .color(colors[lane]), lineWidth: 3)
            if judge.pressed[lane] { context.fill(Path(ellipseIn: ring.insetBy(dx: 6, dy: 6)), with: .color(colors[lane].opacity(0.6))) }
        }
        for (index, note) in judge.notes.enumerated() {
            let held = judge.holding[note.lane] == index
            guard judge.judged[index] == nil || held, note.time - now < lookahead, note.time + note.hold - now > -0.3 else { continue }
            let x = laneX(note.lane, in: size)
            let head = held ? hit : y(note.time, now: now, in: size)
            if note.hold > 0 {
                let tail = y(note.time + note.hold, now: now, in: size)
                context.fill(Path(roundedRect: CGRect(x: x - 11, y: tail, width: 22, height: max(0, head - tail)), cornerRadius: 11),
                             with: .color(colors[note.lane].opacity(held ? 0.9 : 0.55)))
            }
            context.fill(Path(ellipseIn: CGRect(x: x - 24, y: head - 24, width: 48, height: 48)), with: .color(colors[note.lane]))
            context.stroke(Path(ellipseIn: CGRect(x: x - 24, y: head - 24, width: 48, height: 48)), with: .color(.white), lineWidth: 3)
        }
        let bar = CGRect(x: road.maxX + 20, y: hit * 0.25, width: 12, height: hit * 0.75)
        context.fill(Path(roundedRect: bar, cornerRadius: 6), with: .color(.white.opacity(0.2)))
        let filled = bar.height * judge.health
        context.fill(Path(roundedRect: CGRect(x: bar.minX, y: bar.maxY - filled, width: bar.width, height: filled), cornerRadius: 6),
                     with: .color(judge.health > 0.3 ? .green : .red))
        if judge.combo >= 5 {
            context.draw(Text("\(judge.combo) combo").font(.title3.bold()).foregroundStyle(.white),
                         at: CGPoint(x: road.midX, y: hit + 60))
        }
    }
}
