//
//  VoiceModels.swift
//  MaconKit
//
//  Wire types for the live voice mode: the device transcribes speech and sends
//  the conversation so far; the Mac answers with what to SAY (spoken via TTS)
//  and, when the user asked for something to be done, a TASK for the existing
//  dictate-to-drive agent (POST /agent/task) to carry out.
//
//  Routes (CompanionServer):
//    POST /voice/turn   conversation → { say, task? }
//    POST /voice/tts    { text } → WAV audio (Piper on the Mac; 503 = no TTS,
//                       the device falls back to its own voice)
//

import Foundation

/// One conversation turn. `role` is "user" | "assistant".
public struct CompanionVoiceMsgDTO: Codable, Sendable {
    public var role: String
    public var content: String
    public init(role: String, content: String) { self.role = role; self.content = content }
}

/// A voice turn: the running conversation plus the brain to answer with —
/// same provider ids the agent takes ("anthropic" | "openai" | "gemini" |
/// "ollama" | a custom provider id). Keys live on the Mac.
public struct CompanionVoiceTurnRequestDTO: Codable, Sendable {
    public var messages: [CompanionVoiceMsgDTO]
    public var provider: String?
    public var model: String?
    public init(messages: [CompanionVoiceMsgDTO], provider: String? = nil, model: String? = nil) {
        self.messages = messages; self.provider = provider; self.model = model
    }
}

/// The Mac's answer: `say` is spoken aloud on the device; `task`, when set, is
/// something the user asked the Mac to DO — the device submits it to the agent.
public struct CompanionVoiceTurnResponseDTO: Codable, Sendable {
    public var say: String
    public var task: String?
    public init(say: String, task: String? = nil) { self.say = say; self.task = task }
}

/// Synthesize speech for a reply.
public struct CompanionVoiceTTSRequestDTO: Codable, Sendable {
    public var text: String
    public init(text: String) { self.text = text }
}
