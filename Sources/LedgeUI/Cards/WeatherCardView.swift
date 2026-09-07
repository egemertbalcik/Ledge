import LedgeCore
import SwiftUI

/// The weather card, laid out the way Apple's Weather app lays out its header:
/// the place, then the temperature large and light with the condition beneath
/// it, and an hourly strip along the bottom.
///
/// Before this, weather borrowed the generic activity card — an icon in a tinted
/// box, a title, a subtitle, a small temperature off to the right. That reads as
/// a *notification about* the weather rather than the weather itself, which is
/// what made it look out of place next to the media card.
public struct WeatherCardView: View {

    private let payload: WeatherPayload

    @Environment(\.openURL) private var openURL
    @Environment(\.weatherUnits) private var units

    /// The card opens the Weather app on click; nothing said so. A chevron
    /// that appears on hover is how macOS whispers "doorway".

    public init(payload: WeatherPayload) {
        self.payload = payload
    }

    public var body: some View {
        // The whole card is a doorway to the real Weather app, the same way
        // clicking a widget opens its app. A Button rather than a tap gesture:
        // the overlay's own tap handler pins the card, and a gesture would fire
        // alongside it (the route-menu collision).
        //
        // No chevron marking it. One sat in the top-right corner on hover,
        // which is exactly where the condition glyph lives — a moon with
        // sparkles wearing an arrow through it. The card still opens Weather;
        // it just no longer says so by drawing on top of the weather.
        Button {
            openURL(URL(string: "weather://")!)
        } label: {
            VStack(alignment: .leading, spacing: 0) {
                header
                if let minutes = payload.rainSoonMinutes {
                    HStack(spacing: 5) {
                        Image(systemName: "cloud.rain.fill")
                            .symbolRenderingMode(.multicolor)
                            .font(.system(size: 10))
                        Text(minutes == 0 ? "Rain starting" : "Rain in ~\(minutes)m")
                            .font(.cardBody)
                            .foregroundStyle(.white.opacity(0.9))
                    }
                    .padding(.top, 5)
                }
                if !payload.hourly.isEmpty {
                    Divider()
                        .overlay(.white.opacity(0.12))
                        .padding(.vertical, 9)
                    hourlyStrip
                }
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(
            "Weather, \(payload.city.isEmpty ? "Current Location" : payload.city), "
                + "\(Self.degrees(payload.temperatureCelsius, units: units)) degrees, "
                + "\(payload.condition). Opens Weather"
        )
    }

    /// Always on show: "Just now" while fresh, "Updated 12m ago" once the
    /// difference matters. The timestamp is the card's honesty — a failed
    /// refresh silently keeps old numbers, and this is what admits it.
    @ViewBuilder
    private var freshness: some View {
        if payload.fetchedAt > 0 {
            TimelineView(.periodic(from: .now, by: 60)) { context in
                let age = context.date.timeIntervalSinceReferenceDate - payload.fetchedAt
                // Never abbreviated — an admission clipped to "Updated 40m…"
                // admits nothing — but it gives ground rather than taking it
                // from the city: the full phrase where it fits, then the bare
                // age, which says the same thing in a third of the width.
                ViewThatFits(in: .horizontal) {
                    freshnessText(age, prefixed: true)
                    freshnessText(age, prefixed: false)
                }
            }
        }
    }

    private func freshnessText(_ age: TimeInterval, prefixed: Bool) -> some View {
        Text(
            age < 120
                ? "Just now"
                : prefixed ? "Updated \(Self.ago(age)) ago" : "\(Self.ago(age)) ago"
        )
        .font(.system(size: 10))
        .foregroundStyle(.white.opacity(0.35))
        .fixedSize(horizontal: true, vertical: false)
    }

    static func ago(_ seconds: TimeInterval) -> String {
        let sane = seconds.isFinite ? min(max(seconds, 0), 31_536_000) : 0
        let minutes = Int(sane / 60)
        if minutes < 60 { return "\(minutes)m" }
        let hours = minutes / 60
        if hours < 24 { return "\(hours)h" }
        return "\(hours / 24)d"
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(payload.city.isEmpty ? "Current Location" : payload.city)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.white.opacity(0.75))
                        .lineLimit(1)
                        // The name wins the room. It is the one line here that
                        // cannot be inferred from anything else on the card,
                        // and a place clipped to "Newcastle upon T…" is the
                        // card failing at the only thing it has to say first.
                        .layoutPriority(1)
                    // The Weather app's own location arrow — but only when the
                    // reading really did come from the device's location. Beside
                    // a city the user typed it is a false claim, and a pointed
                    // one for anyone who withheld the permission on purpose.
                    if payload.usesDeviceLocation {
                        Image(systemName: "location.fill")
                            .font(.cardFootnote)
                            .foregroundStyle(.white.opacity(0.55))
                            .accessibilityHidden(true)
                    }
                    freshness
                }

                // Ultra-light and large, as the Weather app sets it. The degree
                // sign is a separate, dimmer glyph so the number keeps the eye.
                HStack(alignment: .top, spacing: 0) {
                    Text(Self.degrees(payload.temperatureCelsius, units: units))
                        .font(.system(size: 38, weight: .thin))
                        .foregroundStyle(.white)
                    Text("°")
                        .font(.system(size: 26, weight: .thin))
                        .foregroundStyle(.white.opacity(0.55))
                        .padding(.top, 3)
                }
                .lineLimit(1)
            }

            Spacer(minLength: 0)

            VStack(alignment: .trailing, spacing: 3) {
                Image(systemName: payload.symbolName)
                    // Multicolour, which is what makes a sun yellow and a cloud
                    // grey without the card picking tints by hand.
                    .symbolRenderingMode(.multicolor)
                    .font(.system(size: 24))

                Text(payload.condition)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.white.opacity(0.8))
                    .lineLimit(1)

                if let range = Self.range(high: payload.highCelsius, low: payload.lowCelsius, units: units) {
                    Text(range)
                        .font(.cardBody)
                        .monospacedDigit()
                        .foregroundStyle(.white.opacity(0.5))
                }
            }
        }
    }

    // MARK: - Hourly

    private var hourlyStrip: some View {
        HStack(spacing: 0) {
            ForEach(payload.hourly) { hour in
                VStack(spacing: 5) {
                    Text(hour.isNow ? "Now" : Self.hourLabel(hour.hour))
                        .font(.system(size: 11, weight: hour.isNow ? .semibold : .medium))
                        .foregroundStyle(.white.opacity(hour.isNow ? 0.9 : 0.55))
                        .lineLimit(1)

                    Image(systemName: hour.symbolName)
                        .symbolRenderingMode(.multicolor)
                        .font(.system(size: 14))
                        .frame(height: 16)

                    Text("\(Self.degrees(hour.temperatureCelsius, units: units))°")
                        .font(.system(size: 12, weight: .medium))
                        .monospacedDigit()
                        .foregroundStyle(.white)
                        .lineLimit(1)
                }
                // Equal columns, so the strip reads as a row of hours rather
                // than clustering around whichever labels happen to be wider.
                .frame(maxWidth: .infinity)
            }
        }
    }

    // MARK: - Formatting

    /// Rounded, in the user's scale, and never "-0". The unit is a stored
    /// `WeatherUnits` raw value; the payload itself is always Celsius.
    static func degrees(_ celsius: Double, units: String, locale: Locale = .current) -> String {
        String(WeatherUnits.displayDegrees(celsius: celsius, units: units, locale: locale))
    }

    /// "H:MM"-free, hour only: "3 PM" or "15" depending on the user's clock.
    static func hourLabel(_ hour: Int, locale: Locale = .current) -> String {
        let usesTwentyFourHour = !(
            DateFormatter.dateFormat(fromTemplate: "j", options: 0, locale: locale) ?? ""
        ).contains("a")
        if usesTwentyFourHour { return String(hour) }
        let hour12 = hour % 12 == 0 ? 12 : hour % 12
        return "\(hour12) \(hour < 12 ? "AM" : "PM")"
    }

    /// "H:22°  L:14°", omitted entirely when the service gave neither.
    static func range(high: Double?, low: Double?, units: String, locale: Locale = .current) -> String? {
        switch (high, low) {
        case let (high?, low?):
            return "H:\(degrees(high, units: units, locale: locale))°  L:\(degrees(low, units: units, locale: locale))°"
        case let (high?, nil):
            return "H:\(degrees(high, units: units, locale: locale))°"
        case let (nil, low?):
            return "L:\(degrees(low, units: units, locale: locale))°"
        default:
            return nil
        }
    }
}
