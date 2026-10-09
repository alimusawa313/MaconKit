//
//  Maco.swift
//  MaconKit
//
//  Maco is the Mac as a small character on the phone's Lock Screen and in
//  the Dynamic Island. This file decides what mood it is in, from what the
//  Mac already knows: the coding agents' states, the last build, and how hot
//  the machine is running. The app turns the answer into a Live Activity
//  push; the phone draws the pose and writes the words, so nothing here is
//  user-facing text.
//
//  Pure on purpose: one function from facts to a snapshot, so the rules can
//  be read in one place and tested without a Mac full of agents.
//

import Foundation

public enum MacoMood: String, Codable, Sendable, CaseIterable {
    /// One agent running.
    case working
    /// An agent is waiting on a permission prompt.
    case needsYou
    /// Everything finished a moment ago.
    case done
    /// A build failed a moment ago.
    case oops
    /// Agents are idle and nothing happened for a while.
    case dozing
    /// The Mac is going to sleep.
    case asleep
    /// Two or more agents running.
    case crew
    /// Working, and the Mac is hot.
    case hot
}

/// What the phone needs to draw Maco. Mirrors the companion's
/// MacoActivityAttributes.ContentState field for field; dates as Unix
/// seconds, like the build card, because every encoder on the way agrees on
/// a plain number.
public struct MacoSnapshot: Codable, Sendable, Equatable {
    public var mood: MacoMood
    /// Agents running or waiting.
    public var count: Int
    /// The project the line is about.
    public var project: String?
    /// "claude" | "codex" | …, for the line's subject.
    public var tool: String?
    /// The prompt's summary while waiting, else what the agent is doing.
    public var line: String?
    /// The waiting session and its prompt, so the card can answer it.
    public var agent: String?
    public var seq: Int?
    /// When this mood began.
    public var since: Double

    public init(mood: MacoMood, count: Int = 0, project: String? = nil, tool: String? = nil,
                line: String? = nil, agent: String? = nil, seq: Int? = nil, since: Double) {
        self.mood = mood; self.count = count; self.project = project; self.tool = tool
        self.line = line; self.agent = agent; self.seq = seq; self.since = since
    }

    /// The same moment, ignoring when it began: a card only needs a push
    /// when this changes.
    public func sameLook(as other: MacoSnapshot) -> Bool {
        mood == other.mood && count == other.count && project == other.project
            && tool == other.tool && line == other.line && agent == other.agent && seq == other.seq
    }

    /// The body of GET /maco: {"maco": {...}}, the same fields the phone's
    /// MacoActivityAttributes.ContentState decodes. Nil (the server answers
    /// {}) when there is nothing worth showing.
    public static func routeBody(_ snapshot: MacoSnapshot?) -> Data? {
        guard let snapshot, let body = try? CompanionJSON.encoder.encode(snapshot),
              let json = try? JSONSerialization.jsonObject(with: body) else { return nil }
        return try? JSONSerialization.data(withJSONObject: ["maco": json], options: [.sortedKeys])
    }

    /// The content-state dictionary a Live Activity push carries.
    public var contentState: [String: Any] {
        var state: [String: Any] = ["mood": mood.rawValue, "count": count, "since": since]
        if let project { state["project"] = project }
        if let tool { state["tool"] = tool }
        if let line { state["line"] = line }
        if let agent { state["agent"] = agent }
        if let seq { state["seq"] = seq }
        return state
    }
}

public enum Maco {
    /// How long "done" and "oops" hold before Maco dozes off.
    public static let doneFor: TimeInterval = 15 * 60
    /// How long Maco dozes before the card goes away.
    public static let dozeFor: TimeInterval = 30 * 60

    /// The last build that finished, for "oops" and "done".
    public struct LastBuild: Sendable, Equatable {
        public var passed: Bool
        public var name: String
        public var at: Date
        public init(passed: Bool, name: String, at: Date) {
            self.passed = passed; self.name = name; self.at = at
        }
    }

    /// Maco's mood right now, or nil when there is nothing worth a card.
    ///
    /// In order: a prompt waiting beats everything, because it is the one
    /// mood that asks something of the person. Then agents at work (a crew
    /// when there are several, hot when the Mac is struggling). Then the
    /// last thing that finished, good or bad, for a quarter of an hour. Then
    /// dozing, for half an hour more. Then nothing.
    public static func mood(agents: [CompanionCodingAgentDTO], lastBuild: LastBuild? = nil,
                            hot: Bool = false, now: Date = Date()) -> MacoSnapshot? {
        let waiting = agents.filter { $0.state == "waiting" && $0.prompt != nil }
            .sorted { $0.since < $1.since }
        let running = agents.filter { $0.state == "running" }.sorted { $0.since > $1.since }
        let busy = waiting.count + running.count

        if let first = waiting.first, let prompt = first.prompt {
            return MacoSnapshot(mood: .needsYou, count: busy, project: first.project, tool: first.tool,
                                line: clip("\(prompt.tool): \(prompt.summary)"),
                                agent: first.id, seq: prompt.seq,
                                since: first.since.timeIntervalSince1970)
        }

        if let lead = running.first {
            let began = running.map(\.since).min() ?? lead.since
            let mood: MacoMood = running.count > 1 ? .crew : (hot ? .hot : .working)
            return MacoSnapshot(mood: mood, count: busy, project: lead.project, tool: lead.tool,
                                line: lead.activity.map(clip),
                                since: began.timeIntervalSince1970)
        }

        // Nothing at work: what finished last, an agent's turn or a build?
        let finished = agents.filter { $0.state == "idle" || $0.state == "ended" }
            .max { $0.since < $1.since }
        let agentAt = finished?.since ?? .distantPast
        let buildAt = lastBuild?.at ?? .distantPast
        let lastAt = max(agentAt, buildAt)
        guard lastAt > .distantPast else { return nil }
        let age = now.timeIntervalSince(lastAt)

        if age < doneFor {
            if let build = lastBuild, buildAt >= agentAt {
                return MacoSnapshot(mood: build.passed ? .done : .oops, project: build.name,
                                    since: buildAt.timeIntervalSince1970)
            }
            if let agent = finished {
                return MacoSnapshot(mood: .done, project: agent.project, tool: agent.tool,
                                    line: agent.lastMessage.flatMap(firstLine).map(clip),
                                    since: agentAt.timeIntervalSince1970)
            }
        }
        // Dozing only follows something Maco saw finish; a Mac that has been
        // quiet all along has no card to keep up.
        if age < doneFor + dozeFor {
            return MacoSnapshot(mood: .dozing, project: finished?.project ?? lastBuild?.name,
                                since: lastAt.addingTimeInterval(doneFor).timeIntervalSince1970)
        }
        return nil
    }

    /// A line short enough for the Dynamic Island and far under the 4 KB a
    /// Live Activity push may carry, with anything that looks like a key
    /// masked: it is about to sit on a Lock Screen.
    static func clip(_ text: String) -> String {
        SecretFilter.clean(text, limit: 90)
    }

    static func firstLine(_ text: String) -> String? {
        let line = text.split(separator: "\n").first.map(String.init)?
            .trimmingCharacters(in: .whitespaces)
        return line?.isEmpty == false ? line : nil
    }
}
