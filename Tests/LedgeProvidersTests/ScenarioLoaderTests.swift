import Foundation
import LedgeCore
import Testing

@testable import LedgeProviders

@Suite("Scenario loading")
struct ScenarioLoaderTests {

    private func decode(_ json: String) throws -> Scenario {
        try JSONDecoder().decode(Scenario.self, from: Data(json.utf8))
    }

    @Test("A publish step decodes into a usable activity")
    func decodesPublish() throws {
        let scenario = try decode("""
        {
          "name": "t",
          "steps": [{
            "at": 1.5,
            "action": {
              "type": "publish",
              "activity": {
                "kind": "message",
                "source": "s",
                "expiresAfter": 4,
                "message": { "title": "Hello", "body": "There", "symbolName": "bell.fill" }
              }
            }
          }]
        }
        """)

        #expect(scenario.steps.count == 1)
        #expect(scenario.steps[0].at == 1.5)

        guard case .publish(let scenarioActivity) = scenario.steps[0].action else {
            Issue.record("expected a publish action")
            return
        }
        let activity = try scenarioActivity.activity(createdAt: 100)
        #expect(activity.id == ActivityID(kind: .message, source: "s"))
        #expect(activity.createdAt == 100)
        #expect(activity.expiresAfter == 4)
        #expect(activity.priority == ActivityKind.message.defaultPriority)
    }

    @Test("A retract step decodes")
    func decodesRetract() throws {
        let scenario = try decode("""
        {
          "name": "t",
          "steps": [{
            "at": 0,
            "action": { "type": "retract", "id": { "kind": "focus", "source": "f" } }
          }]
        }
        """)
        guard case .retract(let id) = scenario.steps[0].action else {
            Issue.record("expected a retract action")
            return
        }
        #expect(id == ActivityID(kind: .focus, source: "f"))
    }

    @Test("An unknown action type is rejected rather than silently skipped")
    func rejectsUnknownAction() {
        #expect(throws: (any Error).self) {
            try decode("""
            { "name": "t", "steps": [{ "at": 0, "action": { "type": "explode" } }] }
            """)
        }
    }

    @Test("A step whose payload does not match its kind is rejected")
    func rejectsMismatchedPayload() throws {
        let scenario = try decode("""
        {
          "name": "t",
          "steps": [{
            "at": 0,
            "action": {
              "type": "publish",
              "activity": { "kind": "nowPlaying", "source": "s",
                            "message": { "title": "wrong payload" } }
            }
          }]
        }
        """)
        guard case .publish(let scenarioActivity) = scenario.steps[0].action else {
            Issue.record("expected a publish action")
            return
        }
        // A fixture that declares one kind and carries another must fail loudly
        // rather than render an empty card.
        #expect(throws: ScenarioError.self) {
            try scenarioActivity.activity(createdAt: 0)
        }
    }

    @Test("An explicit priority overrides the kind's default")
    func explicitPriority() throws {
        let scenario = try decode("""
        {
          "name": "t",
          "steps": [{
            "at": 0,
            "action": {
              "type": "publish",
              "activity": { "kind": "nowPlaying", "source": "s", "priority": 99,
                            "nowPlaying": { "title": "a", "artist": "b" } }
            }
          }]
        }
        """)
        guard case .publish(let scenarioActivity) = scenario.steps[0].action else {
            Issue.record("expected a publish action")
            return
        }
        #expect(try scenarioActivity.activity(createdAt: 0).priority == 99)
    }

    @Test("The bundled fixtures in the repository all parse")
    func repositoryFixturesParse() throws {
        // Guards against a fixture being edited into something the app will
        // silently ignore at launch.
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // LedgeProvidersTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // package root
            .appendingPathComponent("Fixtures/scenarios", isDirectory: true)

        let urls = try FileManager.default
            .contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" }

        #expect(!urls.isEmpty, "expected at least one fixture")

        for url in urls {
            let scenario = try ScenarioLoader.load(contentsOf: url)
            #expect(!scenario.steps.isEmpty, "\(url.lastPathComponent) has no steps")
            for step in scenario.steps {
                if case .publish(let scenarioActivity) = step.action {
                    // Throws if the declared kind has no matching payload.
                    _ = try scenarioActivity.activity(createdAt: 0)
                }
            }
        }
    }
}
