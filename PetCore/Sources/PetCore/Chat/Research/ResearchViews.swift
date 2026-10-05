//
//  ResearchViews.swift
//  PetCore
//
//  Research on screen (M28), after Claude's research view: while it runs, a collapsible block with a live timer,
//  the source count, the plan as a timeline and what it's reading; when it's done, a compact "Research complete"
//  header above the report that opens to the same steps.
//

import SwiftUI

/// While research runs.
struct ResearchProgress: View {
    let log: ResearchLog
    @State private var expanded = true

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button { withAnimation(.snappy) { expanded.toggle() } } label: {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(log.isTeam ? "Working it out" : "Researching").font(.callout.weight(.semibold))
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        Text(Self.elapsed(from: log.startedAt, to: context.date)).font(.callout.monospacedDigit()).foregroundStyle(.secondary)
                    }
                    if !log.isTeam { Text("· \(log.sources.count) sources").font(.callout).foregroundStyle(.secondary) }
                    Spacer(minLength: 8)
                    Image(systemName: "chevron.down").rotationEffect(.degrees(expanded ? 0 : -90)).foregroundStyle(.secondary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if expanded {
                ResearchTimeline(log: log, live: true)
                Text(log.status).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    .transition(.opacity)
            }
        }
        .padding(14)
        .frame(maxWidth: 560, alignment: .leading)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(.separator))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(log.isTeam ? "Working it out" : "Researching"), \(log.sources.count) sources so far. \(log.status)")
    }

    static func elapsed(from start: Date, to end: Date) -> String {
        let seconds = max(0, Int(end.timeIntervalSince(start)))
        return seconds < 60 ? "\(seconds)s" : "\(seconds / 60)m \(seconds % 60)s"
    }
}

/// The plan as a timeline (a dot per question, ticking off), then the sources as compact site chips.
struct ResearchTimeline: View {
    let log: ResearchLog
    var live = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(log.steps.enumerated()), id: \.offset) { index, step in
                HStack(alignment: .top, spacing: 10) {
                    VStack(spacing: 0) {
                        Image(systemName: step.done ? "checkmark.circle.fill" : (live ? "circle.dotted" : "circle"))
                            .font(.footnote)
                            .foregroundStyle(step.done ? AnyShapeStyle(.green) : AnyShapeStyle(.secondary))
                        if index < log.steps.count - 1 {
                            Rectangle().fill(.separator).frame(width: 1).frame(minHeight: 12)
                        }
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        Text(step.question).font(.callout)
                        if let note = step.note {
                            Text(note).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                        } else if step.notes > 0 {
                            Text("\(step.notes) findings").font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                    .padding(.bottom, 8)
                }
            }
            if !log.sources.isEmpty { SourceStrip(sources: log.sources) }
        }
    }
}

/// "antartech.co · wikipedia.org · +6": the sites read, opening each page.
struct SourceStrip: View {
    let sources: [ResearchLog.Source]

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(Array(sources.enumerated()), id: \.offset) { index, source in
                    let label = source.url.flatMap { $0.host()?.replacingOccurrences(of: "www.", with: "") } ?? source.title
                    Group {
                        if let url = source.url {
                            Link(destination: url) { chip(index + 1, label) }
                        } else {
                            chip(index + 1, label)
                        }
                    }
                    .help(source.title)
                }
            }
        }
    }

    private func chip(_ number: Int, _ label: String) -> some View {
        HStack(spacing: 4) {
            Text("\(number)").font(.caption2.monospacedDigit().weight(.semibold)).foregroundStyle(.secondary)
            Text(label).font(.caption).lineLimit(1)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(.quaternary.opacity(0.6), in: Capsule())
    }
}

/// Above a finished report: "Research complete · 14 sources · 2m 41s", opening to the steps.
struct ResearchStepsDisclosure: View {
    let log: ResearchLog
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button { withAnimation(.snappy) { expanded.toggle() } } label: {
                HStack(spacing: 8) {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                    Text(log.isTeam ? "How I worked this out" : "Research complete").font(.callout.weight(.semibold))
                    Text((log.isTeam ? "· \(log.steps.count) helpers" : "· \(log.sources.count) sources")
                         + (log.finishedAt.map { " · " + ResearchProgress.elapsed(from: log.startedAt, to: $0) } ?? "")
                         + (log.isTeam ? "" : " · \(log.effort.title) effort"))
                        .font(.callout).foregroundStyle(.secondary)
                    Spacer(minLength: 8)
                    Image(systemName: "chevron.down").rotationEffect(.degrees(expanded ? 0 : -90)).foregroundStyle(.secondary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if expanded { ResearchTimeline(log: log) }
        }
        .padding(12)
        .frame(maxWidth: 560, alignment: .leading)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(.separator))
    }
}

/// The composer's Research button: on/off, with an effort menu beside it.
struct ResearchButton: View {
    @Binding var on: Bool
    @Binding var effort: ResearchEffort

    var body: some View {
        HStack(spacing: 0) {
            Button { on.toggle() } label: {
                HStack(spacing: 5) {
                    Image(systemName: "binoculars")
                    Text("Research")
                }
                .padding(.leading, 12)
                .padding(.trailing, on ? 6 : 12)
                .frame(height: 32)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityValue(on ? "On, \(effort.title) effort" : "Off")
            .help(on ? "Every message runs research" : "Research: plans, reads many sources, writes a cited report")
            if on {
                Menu {
                    Picker("Effort", selection: $effort) {
                        ForEach(ResearchEffort.allCases) { level in
                            Text("\(level.title) · \(level.estimate)").tag(level)
                        }
                    }
                    .pickerStyle(.inline)
                } label: {
                    HStack(spacing: 3) {
                        Text(effort.title)
                        Image(systemName: "chevron.down").font(.caption2.weight(.semibold))
                    }
                    .padding(.trailing, 12)
                    .frame(height: 32)
                }
                .menuStyle(.button)
                .buttonStyle(.plain)
                .menuIndicator(.hidden)
                .fixedSize()
                .accessibilityLabel("Research effort, \(effort.title)")
            }
        }
        .font(.callout.weight(.medium))
        .foregroundStyle(on ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
        .background(on ? AnyShapeStyle(.tint) : AnyShapeStyle(.fill.secondary), in: Capsule())
    }
}
