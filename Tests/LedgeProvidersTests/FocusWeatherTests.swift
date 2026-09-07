import Foundation
import LedgeCore
import Testing

@testable import LedgeProviders
@testable import LedgeSystem

@Suite("Focus parsing")
struct FocusParsingTests {

    private func data(_ json: String) -> Data { Data(json.utf8) }

    @Test("The active mode identifier is pulled from an assertion")
    func activeIdentifier() {
        let json = """
        {"data":[{"storeAssertionRecords":[
          {"assertionDetails":{"assertionDetailsModeIdentifier":"com.apple.focus.work"}}
        ]}]}
        """
        #expect(FileFocusSource.activeModeIdentifier(from: data(json)) == "com.apple.focus.work")
    }

    @Test("No assertions means no active Focus")
    func noAssertions() {
        #expect(FileFocusSource.activeModeIdentifier(from: data("""
        {"data":[{"storeAssertionRecords":[]}]}
        """)) == nil)
    }

    @Test("A localised mode name survives")
    func localisedName() {
        // Verified against a real database: Sleep reads "Uyku", Personal reads
        // "Kişisel" on a Turkish-locale machine.
        let json = """
        {"data":[{"modeConfigurations":{
          "com.apple.sleep.sleep-mode":{"mode":{"name":"Uyku","symbolImageName":"bed.double.fill"}}
        }}]}
        """
        let details = FileFocusSource.modeDetails(from: data(json))
        #expect(details["com.apple.sleep.sleep-mode"]?.name == "Uyku")
    }

    @Test("Garbage yields no result rather than throwing")
    func garbageIsSafe() {
        // This is a private, undocumented file — it will change, and a parse
        // failure must be a missing card, never a crash.
        #expect(FileFocusSource.activeModeIdentifier(from: data("not json")) == nil)
        #expect(FileFocusSource.activeModeIdentifier(from: data("{}")) == nil)
        #expect(FileFocusSource.modeDetails(from: nil).isEmpty)
        #expect(FileFocusSource.modeDetails(from: data("[]")).isEmpty)
    }

    @Test("A built-in mode has a fallback name even with no configuration file")
    func builtInFallback() {
        #expect(FileFocusSource.builtInModes["com.apple.donotdisturb.mode.default"]?.name
            == "Do Not Disturb")
    }
}

@Suite("Focus provider")
@MainActor
struct FocusProviderTests {

    private func collect(
        _ provider: FocusProvider,
        while body: () -> Void
    ) async -> [ProviderEvent] {
        let stream = provider.start()
        body()
        provider.stop()
        var events: [ProviderEvent] = []
        for await event in stream { events.append(event) }
        return events
    }

    @Test("Turning a Focus on publishes an active card")
    func focusOn() async {
        let source = StubFocusSource(value: nil)
        let provider = FocusProvider(source: source)
        let events = await collect(provider) {
            source.set(FocusSnapshot(identifier: "com.apple.focus.work", name: "Work", symbolName: "person.fill"))
        }
        guard case .publish(let activity)? = events.first,
              case .focus(let payload) = activity.payload else {
            Issue.record("expected a focus publish")
            return
        }
        #expect(payload.name == "Work")
        #expect(payload.isActive)
    }

    @Test("A Focus already on at launch is a baseline, not news")
    func focusOnAtLaunchIsSilent() async {
        let source = StubFocusSource(value:
            FocusSnapshot(identifier: "com.apple.focus.work", name: "Work", symbolName: "person.fill"))
        let provider = FocusProvider(source: source)
        // No change during collection — the initial state must not publish.
        let events = await collect(provider) {}
        #expect(events.isEmpty)
    }

    @Test("Turning Focus off publishes an inactive card")
    func focusOff() async {
        let source = StubFocusSource(value:
            FocusSnapshot(identifier: "com.apple.focus.work", name: "Work", symbolName: "person.fill"))
        let provider = FocusProvider(source: source)
        let events = await collect(provider) {
            source.set(nil)
        }
        guard case .publish(let activity)? = events.first,
              case .focus(let payload) = activity.payload else {
            Issue.record("expected a focus publish")
            return
        }
        #expect(!payload.isActive)
    }

    @Test("Nothing is published without Full Disk Access")
    func silentWithoutAccess() async {
        let source = StubFocusSource(
            value: FocusSnapshot(identifier: "x", name: "X", symbolName: "moon.fill"),
            isReadable: false
        )
        let provider = FocusProvider(source: source)
        let events = await collect(provider) {
            source.set(FocusSnapshot(identifier: "y", name: "Y", symbolName: "moon.fill"))
        }
        #expect(events.isEmpty)
    }
}

@Suite("Weather glyph")
struct WeatherGlyphTests {

    @Test("Clear sky is day/night aware")
    func clearGlyph() {
        #expect(WeatherGlyph.describe(code: 0, isDay: true).symbol == "sun.max.fill")
        #expect(WeatherGlyph.describe(code: 0, isDay: false).symbol == "moon.stars.fill")
    }

    @Test("Condition ranges map to sensible symbols")
    func ranges() {
        #expect(WeatherGlyph.describe(code: 63, isDay: true).name == "Rain")
        #expect(WeatherGlyph.describe(code: 73, isDay: true).name == "Snow")
        #expect(WeatherGlyph.describe(code: 95, isDay: true).name == "Thunderstorm")
        #expect(WeatherGlyph.describe(code: 45, isDay: true).name == "Fog")
    }

    @Test("An unknown code degrades to generic cloud rather than crashing")
    func unknownCode() {
        #expect(WeatherGlyph.describe(code: 9999, isDay: true).symbol == "cloud.fill")
    }
}

@Suite("Weather provider")
@MainActor
struct WeatherProviderTests {

    @Test("A snapshot publishes a low-priority standing card")
    func publishesStanding() async {
        let source = StubWeatherSource(value:
            WeatherSnapshot(temperatureCelsius: 21.4, conditionCode: 0, isDay: true, city: "Istanbul"))
        let provider = WeatherProvider(source: source, city: { "Istanbul" }, now: { 0 })

        let stream = provider.start()
        // Give the async fetch a moment to complete.
        for _ in 0..<20 { await Task.yield() }
        provider.stop()

        var events: [ProviderEvent] = []
        for await event in stream { events.append(event) }

        guard case .publish(let activity)? = events.first,
              case .weather(let payload) = activity.payload else {
            Issue.record("expected a weather publish")
            return
        }
        #expect(payload.city == "Istanbul")
        #expect(activity.priority == ActivityKind.weather.defaultPriority)
        // Ambient by design — it must never outrank real news.
        #expect(activity.priority < ActivityKind.nowPlaying.defaultPriority)
    }

    @Test("An empty city publishes nothing and fetches nothing")
    func emptyCityIsSilent() async {
        let source = StubWeatherSource(value:
            WeatherSnapshot(temperatureCelsius: 20, conditionCode: 0, isDay: true, city: "X"))
        let provider = WeatherProvider(source: source, city: { "" }, now: { 0 })

        let stream = provider.start()
        for _ in 0..<20 { await Task.yield() }
        provider.stop()

        var events: [ProviderEvent] = []
        for await event in stream { events.append(event) }
        #expect(events.isEmpty)
        #expect(source.requestedCities.isEmpty, "an empty city must not hit the network")
    }
}

/// Open-Meteo's hourly stamps are wall-clock in the *location's* timezone.
/// Parsing them with the Mac's shifted every hour by the full offset whenever
/// the configured city was not where the machine is.
@Suite("Weather hourly timezone")
struct WeatherHourlyTimezoneTests {

    @Test("The response's utc_offset_seconds decides the parse, not the Mac")
    func offsetDecidesParse() throws {
        let hourly: [String: Any] = [
            "time": ["2030-01-01T12:00"],
            "temperature_2m": [20.0],
        ]
        let atUTC = OpenMeteoWeatherSource.parseHourly(hourly, utcOffsetSeconds: 0)
        let atPlusOne = OpenMeteoWeatherSource.parseHourly(hourly, utcOffsetSeconds: 3600)
        let utcDate = try #require(atUTC.first?.date)
        let plusOneDate = try #require(atPlusOne.first?.date)
        // The same wall-clock stamp an hour east is an earlier instant.
        #expect(utcDate.timeIntervalSince(plusOneDate) == 3600)
    }
}

@Suite("Focus without Full Disk Access")
struct FocusFallbackTests {

    @Test("The database wins when it can be read")
    func databaseWins() {
        let mode = FocusSnapshot(identifier: "com.apple.focus.work", name: "Work", symbolName: "person.lanyardcard.fill")
        let resolved = SystemFocusSource.resolve(fileSnapshot: mode, fileReadable: true, statusFocused: false)
        #expect(resolved == mode, "a readable database is the better source, even against a stale cached status")
    }

    @Test("Without the database, the system's answer stands in — nameless but present")
    func systemAnswerStandsIn() {
        let resolved = SystemFocusSource.resolve(fileSnapshot: nil, fileReadable: false, statusFocused: true)
        #expect(resolved?.name == "Focus")
        #expect(resolved?.symbolName == "moon.fill")
        #expect(resolved != nil, "the card must exist without Full Disk Access — that was the whole bug")
    }

    @Test("Nothing on, or nothing readable, is nothing shown")
    func nothingShown() {
        #expect(SystemFocusSource.resolve(fileSnapshot: nil, fileReadable: false, statusFocused: false) == nil)
        #expect(SystemFocusSource.resolve(fileSnapshot: nil, fileReadable: true, statusFocused: true) == nil,
                "a readable database saying 'no Focus' is the truth")
    }
}
