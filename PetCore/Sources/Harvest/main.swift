//
//  main.swift
//  Harvest
//
//  swift run Harvest --inputs inputs.jsonl --outputs outputs.jsonl [--limit N]
//
//  Keep this in the foreground: FoundationModels throws `rateLimited` for backgrounded apps, and a harvest is
//  long enough that a sleeping Mac will stop it (caffeinate -is swift run … keeps it awake).
//

import Foundation
import PetCore

func value(_ name: String, default fallback: String) -> String {
    guard let i = CommandLine.arguments.firstIndex(of: "--" + name), i + 1 < CommandLine.arguments.count else {
        return fallback
    }
    return CommandLine.arguments[i + 1]
}

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("harvest: \(message)\n".utf8))
    exit(1)
}

let inputsPath = value("inputs", default: "inputs.jsonl")
let outputsPath = value("outputs", default: "outputs.jsonl")
let limit = Int(value("limit", default: "")) ?? Int.max

guard let inputsData = FileManager.default.contents(atPath: inputsPath) else {
    fail("can't read \(inputsPath) — run `apiserver harvest inputs` first")
}
let lines = inputsData.split(separator: UInt8(ascii: "\n")).filter { !$0.isEmpty }
guard let headerLine = lines.first,
      let header = try? JSONDecoder().decode(InputHeader.self, from: Data(headerLine)) else {
    fail("\(inputsPath): no header line")
}
let records = lines.dropFirst().compactMap { try? JSONDecoder().decode(InputRecord.self, from: Data($0)) }
guard records.count == header.count else {
    fail("\(inputsPath): header says \(header.count) users, found \(records.count)")
}

let harvester = try Harvester(outputsPath: outputsPath)
if let reason = harvester.checkAvailability() {
    fail("the on-device model is unavailable — \(reason)")
}

let total = records.reduce(0) { $0 + $1.calls.count }
let remaining = records.reduce(0) { sum, record in
    sum + record.calls.filter { !harvester.isDone(record.id, $0) }.count
}
print("harvest: \(records.count) users, \(total) calls, \(total - remaining) already answered")
if remaining == 0 {
    print("harvest: nothing left to do")
    exit(0)
}

let startedAt = Date.now
var attempted = 0

outer: for record in records {
    for call in record.calls where !harvester.isDone(record.id, call) {
        if attempted >= limit { break outer }
        attempted += 1
        _ = await harvester.answer(id: record.id, call: call)

        if attempted % 20 == 0 || attempted == min(limit, remaining) {
            let elapsed = Date.now.timeIntervalSince(startedAt)
            let perCall = elapsed / Double(attempted)
            let left = Double(min(limit, remaining) - attempted) * perCall
            print(String(
                format: "  %d/%d calls · %.1fs each · about %.0f min left · %d written, %d to retry",
                attempted, min(limit, remaining), perCall, left / 60,
                harvester.tally.written, harvester.tally.failed
            ))
        }
    }
}

let elapsed = Date.now.timeIntervalSince(startedAt)
let minutes = String(format: "%.0f", elapsed / 60)
print("harvest: \(harvester.tally.written) written, \(harvester.tally.failed) to retry, \(minutes) min elapsed → \(outputsPath)")
print("Run again to retry what failed, then: apiserver harvest filter --inputs \(inputsPath) --outputs \(outputsPath)")
