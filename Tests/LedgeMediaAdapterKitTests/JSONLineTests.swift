import Foundation
import LedgeMediaAdapterKit
import Testing

/// What the adapter writes when a player publishes a number JSON cannot hold.
///
/// Found by review: Chromium gives a live stream a duration of +infinity, and
/// `NSJSONSerialization` raises on it rather than returning an error. Uncaught
/// inside perl, that aborted the helper on every start, and after six deaths
/// in half a minute Ledge abandoned it for the session.
@Suite("Numbers and lines the adapter writes")
struct JSONLineTests {

    private static let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()

    @Test("Non-finite numbers become 0, finite ones pass, anything else is 0")
    func finiteOrZero() {
        #expect(ledge_finite_or_zero(NSNumber(value: Double.infinity)) == 0)
        #expect(ledge_finite_or_zero(NSNumber(value: -Double.infinity)) == 0)
        #expect(ledge_finite_or_zero(NSNumber(value: Double.nan)) == 0)
        #expect(ledge_finite_or_zero(NSNumber(value: 206.41)) == 206.41)
        #expect(ledge_finite_or_zero(NSNumber(value: -3)) == -3)
        #expect(ledge_finite_or_zero("12" as NSString) == 0)
        #expect(ledge_finite_or_zero(nil) == 0)
    }

    @Test("Only +infinity reads as a stream with no end")
    func endless() {
        #expect(ledge_is_endless(NSNumber(value: Double.infinity)))
        #expect(!ledge_is_endless(NSNumber(value: -Double.infinity)))
        #expect(!ledge_is_endless(NSNumber(value: Double.nan)), "NaN is unknown, not endless")
        #expect(!ledge_is_endless(NSNumber(value: 600)))
        #expect(!ledge_is_endless(nil))
    }

    @Test("A dictionary holding infinity or NaN is dropped as a line, without raising")
    func badNumbersDropTheLine() throws {
        let infinite: NSDictionary = ["kind": "now", "duration": NSNumber(value: Double.infinity)]
        let nan: NSDictionary = ["kind": "now", "elapsed": NSNumber(value: Double.nan)]
        let nested: NSDictionary = ["kind": "now", "inner": ["rate": NSNumber(value: Double.nan)]]
        // The condition this is about: the writer itself refuses these.
        try #require(!JSONSerialization.isValidJSONObject(infinite))
        try #require(!JSONSerialization.isValidJSONObject(nested))

        #expect(ledge_json_line(infinite as! [AnyHashable: Any]) == nil)
        #expect(ledge_json_line(nan as! [AnyHashable: Any]) == nil)
        #expect(ledge_json_line(nested as! [AnyHashable: Any]) == nil)
    }

    @Test("A clean dictionary is one line of JSON, newline included")
    func cleanLine() throws {
        let line = try #require(ledge_json_line([
            "kind": "now", "duration": ledge_finite_or_zero(NSNumber(value: Double.infinity)), "title": "Radio",
        ]))
        #expect(line.last == 0x0A)
        #expect(line.dropLast().contains(0x0A) == false)
        let back = try #require(try JSONSerialization.jsonObject(with: line.dropLast()) as? [String: Any])
        #expect(back["duration"] as? Double == 0)
        #expect(back["title"] as? String == "Radio")
    }

    /// The adapter's own source, for the wiring this suite cannot run: the
    /// adapter only executes inside perl, against a live MediaRemote.
    @Test("The adapter sends every number and every line through these")
    func adapterUsesThem() throws {
        let adapter = try String(
            contentsOf: Self.root.appending(path: "Sources/LedgeMediaAdapter/LedgeMediaAdapter.m"),
            encoding: .utf8
        )
        let numbers = try #require(adapter.range(of: "static double NumberOrZero(id value) {"))
        #expect(adapter[numbers.upperBound...].prefix(80).contains("return ledge_finite_or_zero(value);"))
        let emit = try #require(adapter.range(of: "static BOOL EmitLine(NSDictionary *object) {"))
        #expect(adapter[emit.upperBound...].prefix(120).contains("ledge_json_line(object)"))
        #expect(!adapter.contains("dataWithJSONObject"), "a direct write can raise again")
        #expect(adapter.contains("ledge_is_endless(info[gKeyDuration])"))
    }
}
