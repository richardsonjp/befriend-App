//
//  TriggerLogUploader.swift
//  PetCore
//

import Foundation
import os

/// Queues trigger events on disk and uploads them in batches. Events are removed only after the server
/// accepted their batch, so nothing is lost offline; re-sent batches are de-duplicated by the server.
public final class TriggerLogUploader {
    private static let log = Logger(subsystem: "com.richardsonjp.befriend", category: "trigger-log")

    nonisolated static let maxQueued = 5_000
    nonisolated static let batchSize = 200
    nonisolated static let flushThreshold = 50
    nonisolated static let flushInterval: Duration = .seconds(60)

    /// Mirrors the server's settings: paused drops new events, excluded apps are never queued.
    public var settings = SyncSettings()

    private let api: APIClient
    private let fileURL: URL
    var queue: [TriggerEventRecord]
    private var isFlushing = false
    private var timer: Task<Void, Never>?

    public init(api: APIClient, fileURL: URL) {
        self.api = api
        self.fileURL = fileURL
        let data = try? Data(contentsOf: fileURL)
        queue = data.flatMap { try? Wire.decoder.decode([TriggerEventRecord].self, from: $0) } ?? []
    }

    /// Uploads every minute until `stop()`.
    public func start() {
        guard timer == nil else { return }
        timer = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.flushInterval)
                await self?.flush()
            }
        }
    }

    public func stop() {
        timer?.cancel()
        timer = nil
    }

    public func record(_ trigger: Trigger, at date: Date = .now) {
        guard !settings.logSyncPaused else { return }
        let event = TriggerEventRecord(trigger: trigger, at: date)
        if let appName = event.appName, settings.excludes(appName: appName) { return }

        queue.append(event)
        if queue.count > Self.maxQueued {
            queue.removeFirst(queue.count - Self.maxQueued)
        }
        persist()
        if queue.count >= Self.flushThreshold {
            Task { await flush() }
        }
    }

    /// Drops queued events, e.g. after the user deleted their activity or signed out.
    public func clear() {
        queue = []
        persist()
    }

    /// Uploads queued events batch by batch; stops at the first failure and keeps the rest for later.
    public func flush() async {
        guard !isFlushing, !settings.logSyncPaused else { return }
        isFlushing = true
        defer { isFlushing = false }

        while !queue.isEmpty {
            let batch = Array(queue.prefix(Self.batchSize))
            do {
                _ = try await api.uploadTriggerEvents(batch)
                remove(batch)
            } catch APIError.server(let status, let code, _) where (400..<500).contains(status) && status != 401 && status != 429 {
                // The server will never take this batch; don't let it block the queue.
                Self.log.error("Dropping \(batch.count) events the server rejected: \(status) \(code, privacy: .public)")
                remove(batch)
            } catch {
                return
            }
        }
    }

    private func remove(_ batch: [TriggerEventRecord]) {
        let sent = Set(batch.map(\.clientEventId))
        queue.removeAll { sent.contains($0.clientEventId) }
        persist()
    }

    private func persist() {
        do {
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Wire.encoder.encode(queue).write(to: fileURL, options: .atomic)
        } catch {
            Self.log.error("Saving the trigger queue failed: \(error.localizedDescription, privacy: .public)")
        }
    }
}
