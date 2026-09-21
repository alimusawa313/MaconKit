//
//  AgentModels.swift
//  MaconKit
//
//  Wire types for the Mac agent: a paired device dictates a task ("open the
//  failing test in Xcode"), the Mac plans it against the accessibility tree
//  and drives itself. The device only submits the task and watches the step
//  feed — the loop runs entirely on the Mac.
//
//  Routes (CompanionServer):
//    POST /agent/eager           a live partial transcript → launch the app it names, now
//    POST /agent/task            start a task → { agent_id }
//    WS   /agent/{id}/events     step feed, one JSON event per frame
//    GET  /agent/{id}/events?after=N   same feed, plain JSON (CLI/debug)
//    POST /agent/{id}/stop       abort the run
//    POST /agent/{id}/decision   approve/skip an awaiting step
//

import Foundation

/// Start a task. The brain is provider-agnostic: any cloud model (Anthropic /
/// OpenAI / Gemini) or a local one through Ollama. Cloud keys ride along like
/// flow keys do — remembered in memory on the Mac, never written to disk.
public struct CompanionAgentTaskRequestDTO: Codable, Sendable {
    public var task: String
    /// "supervised" (every step waits for approval) | "auto".
    public var mode: String?
    /// "anthropic" | "openai" | "gemini" | "ollama" (default anthropic).
    public var provider: String?
    /// Model id; empty → the provider's default.
    public var model: String?
    /// Cloud API key for the provider (nil for ollama or already remembered).
    public var key: String?
    public var maxSteps: Int?
    /// The user's previous commands in this conversation, oldest first. "And
    /// search MKBHD" only means something after "open chrome".
    public var context: [String]?
    /// What lets this Mac spend Macon's Jev. The device mints it by proving
    /// its subscription; it carries no secret and expires on its own, so it
    /// is safe on the wire and useless to anyone but Macon's relay.
    public var grant: String?

    public init(task: String, mode: String? = nil, provider: String? = nil,
                model: String? = nil, key: String? = nil, maxSteps: Int? = nil,
                context: [String]? = nil, grant: String? = nil) {
        self.task = task; self.mode = mode; self.provider = provider
        self.model = model; self.key = key; self.maxSteps = maxSteps
        self.context = context; self.grant = grant
    }
}

public struct CompanionAgentStartResponseDTO: Codable, Sendable {
    public var agentId: String
    public init(agentId: String) { self.agentId = agentId }
}

/// One step-feed entry. `kind` is the discriminator:
///   plan / replan  — `steps` lists the intended actions
///   action         — one step; `status` = running | ok | fail | skipped
///   approval       — waiting for a decision on step `step` (answer with seq)
///   done / error / stopped — terminal
public struct CompanionAgentEventDTO: Codable, Sendable {
    public var seq: Int
    public var kind: String
    public var text: String
    public var steps: [String]?
    public var status: String?
    public var step: Int?

    public init(seq: Int, kind: String, text: String,
                steps: [String]? = nil, status: String? = nil, step: Int? = nil) {
        self.seq = seq; self.kind = kind; self.text = text
        self.steps = steps; self.status = status; self.step = step
    }
}

/// Approve or skip the step named by an `approval` event's seq.
/// A partial transcript, sent while the user is STILL TALKING. If it names an
/// app that isn't frontmost, the Mac opens it right away, no model involved —
/// which is what lets the app appear before the sentence ends. Everything else
/// waits for the full utterance and the real task.
public struct CompanionAgentEagerRequestDTO: Codable, Sendable {
    public var text: String
    /// Carried here too: a launch mid-sentence may be the first thing a device
    /// asks for, before any task has handed a grant over.
    public var grant: String?
    public init(text: String, grant: String? = nil) { self.text = text; self.grant = grant }
}

public struct CompanionAgentEagerResponseDTO: Codable, Sendable {
    /// The app that was just launched, or nil when nothing was (no app named,
    /// or it was already in front).
    public var launched: String?
    public init(launched: String?) { self.launched = launched }
}

public struct CompanionAgentDecisionDTO: Codable, Sendable {
    public var seq: Int
    public var approve: Bool
    public init(seq: Int, approve: Bool) { self.seq = seq; self.approve = approve }
}
