import Foundation
import LedgeCore
import LedgeSystem

/// Everything the app needs to know about one activity source without
/// constructing it.
///
/// The point is that adding a provider is a single entry here plus its own
/// file — no edits to the composition root, no new preference, no new settings
/// control. Before this, every provider was hand-wired into
/// `LedgeCoordinator.startActivities()`, which does not scale past the one or
/// two that existed.
public struct ProviderRegistration: Identifiable, Sendable {

    /// Stable across releases: it is persisted in the disabled-providers
    /// preference, so renaming one silently re-enables it.
    public let id: String

    public let displayName: String

    /// What this provider publishes. Used to describe it in settings.
    public let kind: ActivityKind

    /// The permission it needs, or nil if it needs none.
    public let permission: PermissionKind?

    /// True when the permission only *improves* the provider rather than
    /// enabling it, so it runs whatever the permission says.
    ///
    /// The permission is still declared, because Settings lists it and
    /// granting it visibly adds something — it just may not decide whether the
    /// card exists at all.
    public let permissionIsOptional: Bool

    public let isEnabledByDefault: Bool

    /// Deferred construction, so a disabled provider is never built and a
    /// provider needing a permission is not created until it can run.
    public let make: @MainActor () -> any ActivityProvider

    public init(
        id: String,
        displayName: String,
        kind: ActivityKind,
        permission: PermissionKind? = nil,
        permissionIsOptional: Bool = false,
        isEnabledByDefault: Bool = true,
        make: @escaping @MainActor () -> any ActivityProvider
    ) {
        self.id = id
        self.displayName = displayName
        self.kind = kind
        self.permission = permission
        self.permissionIsOptional = permissionIsOptional
        self.isEnabledByDefault = isEnabledByDefault
        self.make = make
    }
}

/// The table of every provider the app can run.
///
/// Deliberately *not* a static constant: the media provider needs a source
/// chosen by an async capability probe, so the registry is built with whatever
/// the shell has already resolved.
@MainActor
public enum ProviderRegistry {

    /// Builds the table.
    ///
    /// - Parameter nowPlayingProvider: constructed by the shell after the
    ///   MediaRemote probe decides which source to use. Passed in rather than
    ///   built here so the registry stays free of that async dance.
    public static func all(
        nowPlayingProvider: @escaping @MainActor () -> any ActivityProvider,
        weatherCity: @escaping @MainActor () -> String = { "" },
        timerProvider: @escaping @MainActor () -> any ActivityProvider = { TimerProvider() },
        // Defaults to an ephemeral shelf so callers that do not care — tests,
        // the preview — need not build a store.
        shelfProvider: @escaping @MainActor () -> any ActivityProvider = {
            ShelfProvider(store: ShelfStore(load: { "" }, save: { _ in }))
        },
        // The shell keeps its own Focus source for the quiet-during-Focus
        // rule, which has to work whether or not the *card* is switched on.
        // It passes that same source in here rather than letting a second one
        // be built: two of them watch the same folder, run two timers, and ask
        // the system the same question a millisecond apart — and because each
        // keeps its own idea of the answer, they announce changes against each
        // other's state. That was a Focus card peeking on and off every four
        // seconds for as long as a Focus was on.
        focusSource: @escaping @MainActor () -> any FocusSource = { SystemFocusSource() }
    ) -> [ProviderRegistration] {
        [
            ProviderRegistration(
                // Lower-case to match `NowPlayingProvider.identifier`; see the
                // note on the AirPods registration below.
                id: "nowplaying",
                displayName: "Music",
                kind: .nowPlaying,
                permission: .automation,
                // Automation buys cover art and seeking for Music and Spotify.
                // It does not buy the card: the MediaRemote adapter reads what
                // is playing system-wide without asking anyone. Gating the
                // provider on it meant a Mac that had never granted Automation
                // showed no media at all — and one where the permission query
                // itself hung showed none either.
                permissionIsOptional: true,
                make: nowPlayingProvider
            ),

            ProviderRegistration(
                id: "battery",
                displayName: "Battery",
                kind: .power,
                // Power state is public IOKit — nothing to ask for.
                permission: nil,
                make: { BatteryProvider(source: IOKitPowerSource()) }
            ),

            ProviderRegistration(
                id: "bluetooth",
                displayName: "AirPods & Devices",
                kind: .device,
                // Listed as a *soft* requirement. Connection and battery come
                // from `system_profiler`, which carries its own entitlement and
                // works regardless; only the live connect/disconnect push goes
                // through IOBluetooth, which macOS 14 brought under the same
                // TCC service as CoreBluetooth. Without the grant the provider
                // still runs, it just stops noticing changes as they happen.
                permission: .bluetooth,
                permissionIsOptional: true,
                make: { BluetoothProvider(source: IOBluetoothDeviceSource()) }
            ),

            ProviderRegistration(
                // Must match `AirPodsProximityProvider.identifier`: the hub keys
                // on the provider's own identifier, so a registration id that
                // merely looks right makes `setProvider(_:enabled:)` a silent
                // no-op. `ProviderRegistryTests` now guards every registration.
                id: "airpods-proximity",
                displayName: "AirPods Case Opens",
                kind: .device,
                // Runs a continuous BLE scan and needs real Bluetooth access, so
                // it was once declared off-by-default. It has always run, though,
                // and the case-open animation is a feature people rely on;
                // honouring the flag
                // now would silently remove it on upgrade, so the default follows
                // the behaviour that actually shipped. The scan is still gated on
                // the Bluetooth permission, and the toggle is in Settings.
                permission: .bluetooth,
                make: { AirPodsProximityProvider() }
            ),

            ProviderRegistration(
                id: "audioroute",
                displayName: "Where Sound Goes",
                kind: .device,
                // One CoreAudio property listener. Which device plays sound is
                // not private and needs nothing granted.
                permission: nil,
                make: { AudioRouteProvider() }
            ),

            ProviderRegistration(
                id: "bluetooth-power",
                displayName: "Bluetooth On & Off",
                kind: .device,
                // CBCentralManager is the only public way to see the switch,
                // and creating one is what asks for Bluetooth.
                permission: .bluetooth,
                make: { BluetoothPowerProvider() }
            ),

            ProviderRegistration(
                id: "keyboard",
                displayName: "Keyboard Layout",
                kind: .keyboard,
                // Text Input Sources needs no permission: the selected layout is
                // not private data and the notification is public.
                permission: nil,
                make: { KeyboardLayoutProvider() }
            ),

            ProviderRegistration(
                id: "capslock",
                displayName: "Caps Lock",
                kind: .keyboard,
                // A global monitor observes without intercepting, but macOS
                // only delivers it with the Accessibility grant.
                permission: .accessibility,
                make: { CapsLockProvider() }
            ),

            ProviderRegistration(
                id: "calendar",
                displayName: "Calendar",
                kind: .event,
                // Hard-gated in effect: the source reads nothing until Calendar
                // access is granted, and never prompts on its own — the prompt
                // belongs to the Permissions tab.
                permission: .calendars,
                make: { CalendarProvider(source: EventKitCalendarSource()) }
            ),

            ProviderRegistration(
                id: "focus",
                displayName: "Focus Modes",
                kind: .focus,
                // The system's own on/off answer, behind an ordinary prompt —
                // preferred, and not the only way in. Given the Focus database
                // folder, the source reads the mode straight from it, name and
                // all, without the permission; requiring the grant anyway left
                // a card that had everything it needed and was not allowed to
                // run. Optional, like the weather's location.
                permission: .focusStatus,
                permissionIsOptional: true,
                make: { FocusProvider(source: focusSource()) }
            ),

            ProviderRegistration(
                id: "weather",
                displayName: "Weather",
                kind: .weather,
                // Location is preferred but never required: without the grant
                // the provider falls back to the typed city, so the feature
                // still works and nothing prompts on its own.
                permission: .location,
                permissionIsOptional: true,
                make: {
                    WeatherProvider(
                        source: OpenMeteoWeatherSource(),
                        city: weatherCity,
                        location: CoreLocationSource()
                    )
                }
            ),

            ProviderRegistration(
                id: "levels",
                displayName: "Sound & Brightness",
                kind: .levels,
                permission: nil,
                make: { LevelsProvider() }
            ),

            ProviderRegistration(
                id: "timer",
                displayName: "Timer & Stopwatch",
                kind: .timer,
                // Driven entirely by the user from the menu bar; nothing to ask
                // the system for, so no permission at all.
                permission: nil,
                make: timerProvider
            ),

            ProviderRegistration(
                id: "shelf",
                displayName: "File Shelf",
                kind: .shelf,
                // Dropped files are read directly — the app is not sandboxed, so
                // there is nothing to ask for.
                permission: nil,
                make: shelfProvider
            ),

            ProviderRegistration(
                id: "privacy",
                displayName: "Camera & Mic",
                kind: .privacy,
                // Reading a device's running state starts no capture session, so
                // this triggers no TCC prompt and needs no permission.
                permission: nil,
                make: { PrivacyProvider(source: SystemRecordingSource()) }
            ),
        ]
    }

    /// Descriptors for the settings UI, with the user's choices folded in.
    public static func descriptors(
        _ registrations: [ProviderRegistration],
        isEnabled: (String) -> Bool,
        isPermitted: (PermissionKind) -> Bool
    ) -> [ProviderDescriptor] {
        registrations.map { registration in
            ProviderDescriptor(
                id: registration.id,
                displayName: registration.displayName,
                kind: registration.kind,
                permission: registration.permission,
                isEnabled: isEnabled(registration.id),
                isAvailable: registration.permissionIsOptional
                    || (registration.permission.map(isPermitted) ?? true)
            )
        }
    }
}
