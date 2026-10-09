import XCTest
@testable import MaconKit

final class MacoTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func agent(_ id: String, _ state: String, ago: TimeInterval = 60, project: String = "app",
                       prompt: CompanionCodingAgentPromptDTO? = nil, message: String? = nil,
                       activity: String? = nil, decisions: Int = 0) -> CompanionCodingAgentDTO {
        var a = CompanionCodingAgentDTO(id: id, tool: "claude", project: project, cwd: "/tmp/\(project)",
                                        state: state, since: now.addingTimeInterval(-ago),
                                        startedAt: now.addingTimeInterval(-3600))
        a.prompt = prompt
        a.lastMessage = message
        a.activity = activity
        a.decisions = decisions
        return a
    }

    private func prompt(_ seq: Int) -> CompanionCodingAgentPromptDTO {
        CompanionCodingAgentPromptDTO(seq: seq, tool: "Bash", summary: "git push", askedAt: now)
    }

    /// GET /maco speaks the phone's ContentState: these keys, plain
    /// words, the mood as its raw value, `since` in Unix seconds.
    func testRouteBodyMatchesThePhone() throws {
        let snap = MacoSnapshot(mood: .needsYou, count: 2, project: "macon-web", tool: "claude",
                                line: "Bash: rm -rf build/", agent: "claude-7f21", seq: 7, since: 1_791_562_196)
        let data = try XCTUnwrap(MacoSnapshot.routeBody(snap))
        let top = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let maco = try XCTUnwrap(top["maco"] as? [String: Any])
        XCTAssertEqual(Set(maco.keys), ["mood", "count", "project", "tool", "line", "agent", "seq", "since"])
        XCTAssertEqual(maco["mood"] as? String, "needsYou")
        XCTAssertEqual(maco["seq"] as? Int, 7)
        XCTAssertEqual(maco["since"] as? Double, 1_791_562_196)
        XCTAssertNil(MacoSnapshot.routeBody(nil))
    }

    func testRouteBodyLeavesOutWhatIsMissing() throws {
        let data = try XCTUnwrap(MacoSnapshot.routeBody(MacoSnapshot(mood: .dozing, since: 10)))
        let maco = try XCTUnwrap((JSONSerialization.jsonObject(with: data) as? [String: Any])?["maco"] as? [String: Any])
        XCTAssertEqual(Set(maco.keys), ["mood", "count", "since"])
    }

    func testNothingMeansNoCard() {
        XCTAssertNil(Maco.mood(agents: [], now: now))
    }

    func testWaitingBeatsEverything() {
        let snap = Maco.mood(agents: [agent("a", "running"), agent("b", "waiting", prompt: prompt(7))],
                             hot: true, now: now)
        XCTAssertEqual(snap?.mood, .needsYou)
        XCTAssertEqual(snap?.agent, "b")
        XCTAssertEqual(snap?.seq, 7)
        XCTAssertEqual(snap?.count, 2)
        XCTAssertEqual(snap?.line, "Bash: git push")
    }

    func testRunningMoods() {
        XCTAssertEqual(Maco.mood(agents: [agent("a", "running")], now: now)?.mood, .working)
        XCTAssertEqual(Maco.mood(agents: [agent("a", "running")], hot: true, now: now)?.mood, .hot)
        XCTAssertEqual(Maco.mood(agents: [agent("a", "running"), agent("b", "running")], now: now)?.mood, .crew)
    }

    func testDoneThenDozingThenGone() {
        let fresh = Maco.mood(agents: [agent("a", "idle", ago: 60, message: "All done.\nMore")], now: now)
        XCTAssertEqual(fresh?.mood, .done)
        XCTAssertEqual(fresh?.line, "All done.")
        XCTAssertEqual(Maco.mood(agents: [agent("a", "idle", ago: 20 * 60)], now: now)?.mood, .dozing)
        XCTAssertNil(Maco.mood(agents: [agent("a", "idle", ago: 50 * 60)], now: now))
    }

    func testNewerBuildDecides() {
        let failed = Maco.LastBuild(passed: false, name: "ci", at: now.addingTimeInterval(-30))
        let snap = Maco.mood(agents: [agent("a", "idle", ago: 120)], lastBuild: failed, now: now)
        XCTAssertEqual(snap?.mood, .oops)
        XCTAssertEqual(snap?.project, "ci")
        let older = Maco.LastBuild(passed: false, name: "ci", at: now.addingTimeInterval(-600))
        XCTAssertEqual(Maco.mood(agents: [agent("a", "idle", ago: 60)], lastBuild: older, now: now)?.mood, .done)
    }

    func testLinesAreCleaned() {
        let snap = Maco.mood(agents: [agent("a", "running", activity: "Bash: export KEY=sk-abcdefghijklmnopqrstuvwxyz")],
                             now: now)
        XCTAssertFalse(snap?.line?.contains("abcdefghijklmnop") ?? true)
    }

    func testSecretFilter() {
        XCTAssertEqual(SecretFilter.clean("token: abc123def456"), "•••")
        XCTAssertTrue(SecretFilter.clean("use ghp_0123456789abcdefghij0123 now").contains("•••"))
        XCTAssertEqual(SecretFilter.clean("Fixed the login button"), "Fixed the login button")
        XCTAssertEqual(SecretFilter.clean(String(repeating: "a ", count: 200), limit: 10).count, 10)
    }
}

final class RecapJournalTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    private func agent(_ state: String, at: TimeInterval, decisions: Int = 0,
                       prompt: CompanionCodingAgentPromptDTO? = nil) -> CompanionCodingAgentDTO {
        var a = CompanionCodingAgentDTO(id: "s1", tool: "claude", project: "app", cwd: "/tmp/app",
                                        state: state, since: t0.addingTimeInterval(at),
                                        startedAt: t0)
        a.decisions = decisions
        a.prompt = prompt
        a.lastMessage = state == "idle" ? "Shipped the login screen" : nil
        return a
    }

    func testTurnPromptAnswerAndFinish() {
        let journal = RecapJournal()
        journal.observe([agent("running", at: 0)], now: t0)
        let p = CompanionCodingAgentPromptDTO(seq: 1, tool: "Bash", summary: "npm test",
                                              askedAt: t0.addingTimeInterval(60))
        journal.observe([agent("waiting", at: 60, prompt: p)], now: t0.addingTimeInterval(60))
        journal.observe([agent("running", at: 90, decisions: 1)], now: t0.addingTimeInterval(90))
        journal.observe([agent("idle", at: 600, decisions: 1)], now: t0.addingTimeInterval(600))

        let recap = journal.recap(since: t0.addingTimeInterval(-1), now: t0.addingTimeInterval(700),
                                  macName: "Mac", live: [], audit: [], requester: "me",
                                  commits: { _, _ in nil })
        XCTAssertEqual(recap.items.map(\.kind), ["agent.waiting", "agent.answered", "agent.done"])
        XCTAssertEqual(recap.items.last?.text, "Shipped the login screen")
        XCTAssertEqual(recap.items.last?.seconds ?? 0, 600, accuracy: 0.5)
        XCTAssertEqual(recap.workedSeconds, 600, accuracy: 0.5)
        XCTAssertEqual(recap.answered, 1)
    }

    func testWindowAndAuditFiltering() {
        let journal = RecapJournal()
        journal.noteBuild(passed: true, name: "ci", detail: nil, at: t0)
        journal.noteBuild(passed: false, name: "ci", detail: "exit 1", at: t0.addingTimeInterval(100))
        let audit = [
            AuditEntry(at: t0.addingTimeInterval(50), device: "ipad0001", deviceName: "iPad", action: "terminal.opened"),
            AuditEntry(at: t0.addingTimeInterval(60), device: "ipad0001", deviceName: "iPad", action: "terminal.opened"),
            AuditEntry(at: t0.addingTimeInterval(70), device: "phone001", deviceName: "Phone", action: "unlocked"),
            AuditEntry(at: t0.addingTimeInterval(80), device: "ipad0001", deviceName: "iPad", action: "clipboard.pushed"),
        ]
        let recap = journal.recap(since: t0.addingTimeInterval(10), now: t0.addingTimeInterval(200),
                                  macName: "Mac", live: [], audit: audit, requester: "phone001",
                                  commits: { _, _ in nil })
        XCTAssertEqual(recap.items.map(\.kind), ["build.failed"])
        XCTAssertEqual(recap.audit.count, 1)
        XCTAssertEqual(recap.audit.first?.count, 2)
        XCTAssertEqual(recap.audit.first?.action, "terminal.opened")
    }

    func testOverlapsCountOnce() {
        let spans = [RecapJournal.Span(start: t0, end: t0.addingTimeInterval(100)),
                     RecapJournal.Span(start: t0.addingTimeInterval(50), end: t0.addingTimeInterval(150)),
                     RecapJournal.Span(start: t0.addingTimeInterval(300), end: t0.addingTimeInterval(400))]
        XCTAssertEqual(RecapJournal.covered(spans, from: t0, to: t0.addingTimeInterval(350)), 200, accuracy: 0.01)
    }

    func testSurvivesRestart() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("recap-\(UUID()).json")
        defer { try? FileManager.default.removeItem(at: url) }
        RecapJournal(url: url).noteBuild(passed: true, name: "ci", detail: nil, at: Date())
        let again = RecapJournal(url: url)
        let recap = again.recap(since: Date().addingTimeInterval(-60), macName: "Mac", live: [],
                                audit: [], requester: "x", commits: { _, _ in nil })
        XCTAssertEqual(recap.items.map(\.kind), ["build.passed"])
    }
}
