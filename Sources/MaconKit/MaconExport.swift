//
//  MaconExport.swift
//  MaconKit
//
//  A portable snapshot of an app setup — pipelines plus (optionally) the
//  credentials and secrets needed to run them — so the same configuration can
//  be handed to the `macon` CLI or another machine.
//

import Foundation

public struct MaconExport: Codable {
    /// Bumped if the on-disk shape ever changes incompatibly.
    public var version: Int = 1

    /// Bitbucket login email (not sensitive on its own; the token is).
    public var bitbucketEmail: String?
    /// Present only when exported *with* secrets.
    public var bitbucketToken: String?
    public var githubToken: String?

    /// Every pipeline's configuration.
    public var pipelines: [PipelineConfig]

    /// Secret values by scope — the key is `"global"` or a pipeline's UUID string.
    /// Present only when exported with secrets; omitted otherwise (names still
    /// live in each `PipelineConfig.secretKeys`, values come from the env).
    public var secrets: [String: [String: String]]?

    public init(pipelines: [PipelineConfig]) { self.pipelines = pipelines }

    /// Whether this bundle carries any secret/token values (vs config only).
    public var includesSecrets: Bool {
        bitbucketToken != nil || githubToken != nil || (secrets?.isEmpty == false)
    }

    public func encoded() throws -> Data {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try enc.encode(self)
    }

    public static func decoded(from data: Data) throws -> MaconExport {
        try JSONDecoder().decode(MaconExport.self, from: data)
    }
}
