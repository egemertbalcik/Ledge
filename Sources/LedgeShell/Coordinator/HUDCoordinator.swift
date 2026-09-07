import AppKit
import Foundation
import LedgeCore
import LedgeSystem
import LedgeUI
import os

/// Drives the level HUD.
///
/// Two ways in, and they are not equivalent:
///
/// - **Observing** (default). CoreAudio reports volume changes, brightness is
///   polled. No permission, no event tap, nothing intercepted — the system's
///   own HUD still appears alongside ours.
/// - **Intercepting** (opt-in, needs Accessibility). The key press is swallowed
///   and this app applies the change itself, so the system never learns the key
///   was pressed and never draws its HUD.
///
/// The second is what people actually want to look at, and also the one that
/// can leave the volume keys doing nothing if it goes wrong. Hence the split.
@MainActor
public final class HUDCoordinator {

    private static let log = Logger(subsystem: "com.egemert.ledge", category: "hud")

    private let preferences: Preferences
    private let presentation: NotchPresentation

    private let volume = VolumeController()
    private let brightness = BrightnessController()
    /// Per-display brightness. `brightness` above still watches the built-in
    /// panel for externally-made changes; this one applies levels, to whichever
    /// display the user means.
    private let displayBrightness = DisplayBrightnessController()

    /// Coalesces the external-brightness preference write.
    ///
    /// Dragging the panel's slider calls `adjustBrightness` once per frame, and
    /// writing `UserDefaults` at 60 Hz to record a level the user is still in
    /// the middle of choosing is pure waste. The value is held in the controller
    /// either way; this only decides when it is written down.
    private var brightnessPersistTask: Task<Void, Never>?
    private let interceptor = MediaKeyInterceptor()

    /// Asks the shell to show the HUD phase.
    public var onReadout: (HUDReadout) -> Void = { _ in }

    public init(preferences: Preferences, presentation: NotchPresentation) {
        self.preferences = preferences
        self.presentation = presentation
    }

    public func start() {
        volume.onChange = { [weak self] readout in self?.show(readout) }
        brightness.onChange = { [weak self] readout in
            guard let self else { return }
            // Brightness has no change notification, so the watcher *polls* and
            // guesses whether a change was the user by its size. Ambient
            // auto-brightness breaks that guess: walking into sunlight moves the
            // backlight further between two samples than a key press does, and
            // the readout appears for something the user never did.
            //
            // When the interceptor is running there is no need to guess. The
            // key press itself is the signal, `handleBrightness` shows the
            // readout, and the poll goes back to being what its own comment
            // calls it — a display-sync backstop. Only when suppression is off
            // is the poll the sole source, and the size heuristic the best
            // available.
            guard !self.isSuppressing else { return }
            self.show(readout)
        }
        interceptor.onPress = { [weak self] press in
            self?.handle(press) ?? false
        }
        // A gamma ramp does not survive the process that set it, so an external
        // display comes back at full every launch until this re-applies.
        displayBrightness.loadLevels(preferences.externalBrightness)
        displayBrightness.restoreRememberedLevels()
        apply()
    }

    /// Re-decides whether the readout can be suppressed.
    ///
    /// Called when Accessibility is found to have changed under the app. On a
    /// loss the system has already killed the tap; this stops pretending
    /// otherwise, hands the readout back to macOS, and starts waiting for the
    /// grant to return.
    public func revalidateTrust() {
        apply()
    }

    public func stop() {
        trustRetry?.cancel()
        trustRetry = nil
        volume.stopWatching()
        brightness.stopWatching()
        interceptor.stop()
        // Flush rather than wait out the debounce — `stop()` may be the last
        // thing that runs.
        brightnessPersistTask?.cancel()
        brightnessPersistTask = nil
        preferences.externalBrightness = displayBrightness.encodedLevels()
        displayBrightness.releaseAll()
    }

    /// Polls for the Accessibility grant while suppression is wanted but not yet
    /// permitted. Granting in System Settings does not re-run `apply()` on its
    /// own, and without this the user would have to quit and relaunch for
    /// suppression to begin. Runs only in the ungranted window, then stops.
    private var trustRetry: Task<Void, Never>?

    private func waitForTrust() {
        trustRetry?.cancel()
        trustRetry = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                guard let self else { return }
                if MediaKeyInterceptor.isTrusted {
                    self.apply()   // starts the tap and cancels this task
                    return
                }
            }
        }
    }

    /// Re-reads the preferences and reconfigures. Called at startup and again
    /// whenever the HUD settings change.
    public func apply() {
        guard preferences.hudEnabled else {
            stop()
            Self.log.notice("HUD disabled")
            return
        }

        volume.startWatching()
        applyBrightnessWatching()

        // Re-enabling after a disable must bring the external dim back the
        // same way a launch does — `stop()` released the ramps, and without
        // this the remembered levels only returned at the next app start.
        // Idempotent when nothing was released.
        displayBrightness.loadLevels(preferences.externalBrightness)
        displayBrightness.restoreRememberedLevels()

        // Interception is only attempted when the user asked for suppression
        // *and* the permission is already granted. It never prompts on its own;
        // the Settings toggle does that, from an explicit click.
        // Diagnostic: the current grant state in a stable file, so it can be
        // verified after a LaunchServices launch (no stderr to read) and after
        // a live grant that `waitForTrust` picks up. Opt-in like the other
        // diagnostic dotfiles — a stranger's home directory is not a log.
        if DebugSwitches.isOn("LEDGE_HUD_DIAG") {
            let trustPath = (NSHomeDirectory() as NSString).appendingPathComponent(".ledge-hud-trust")
            try? "suppress=\(preferences.suppressSystemHUD) trusted=\(MediaKeyInterceptor.isTrusted)"
                .write(toFile: trustPath, atomically: true, encoding: .utf8)
        }

        if preferences.suppressSystemHUD, MediaKeyInterceptor.isTrustedNow {
            trustRetry?.cancel()
            trustRetry = nil
            let started = interceptor.start(suppressSystemHUD: true)
            Self.log.notice("native HUD suppression \(started ? "active" : "FAILED to start", privacy: .public)")
            if !started {
                Self.log.error("suppression requested but the tap did not start")
            }
            applyBrightnessWatching()
        } else {
            interceptor.stop()
            applyBrightnessWatching()
            if preferences.suppressSystemHUD {
                Self.log.notice("suppression requested but Accessibility is not granted — waiting")
                // Begin the tap the moment the grant lands, no relaunch needed.
                waitForTrust()
            } else {
                // Suppression switched off while the trust poll was running:
                // without this the 2-second AXIsProcessTrusted loop outlives
                // the wish that started it, for the rest of the app's life.
                trustRetry?.cancel()
                trustRetry = nil
            }
        }
    }

    public var isSuppressing: Bool { interceptor.isRunning }

    /// The screens are dark (asleep or locked): the brightness poll stands
    /// down until they light again. Set by the coordinator.
    public func setDormant(_ dormant: Bool) {
        guard dormant != isDormant else { return }
        isDormant = dormant
        applyBrightnessWatching()
    }
    private var isDormant = false

    /// The brightness watcher polls (there is no change notification), so it
    /// runs only when something consumes its readouts: brightness HUD on, the
    /// screens lit, and the interceptor *not* running — with suppression
    /// active the key press itself is the signal and `onChange` discards the
    /// poll's readout, so the poll would be two wake-ups a second for nothing.
    private func applyBrightnessWatching() {
        let wanted = preferences.hudEnabled && preferences.hudBrightnessEnabled
            && !isDormant && !interceptor.isRunning
        if wanted { brightness.startWatching() } else { brightness.stopWatching() }
    }

    /// Re-reads the current output's level and shows it — used after the user
    /// switches the route from the panel, so the slider tracks the new device.
    public func refreshVolumeReadout() {
        guard let readout = volume.readout() else { return }
        show(readout)
    }

    /// Applies a level set directly from the HUD's draggable bar.
    public func adjust(_ kind: HUDReadout.Kind, to level: Double) {
        let clamped = min(max(level, 0), 1)
        switch kind {
        case .volume:
            guard let device = VolumeController.defaultOutputDevice() else { return }
            if clamped > 0, VolumeController.isMuted(device) {
                VolumeController.setMuted(false, on: device)
            }
            VolumeController.noteSelfWrite()
            guard VolumeController.setLevel(clamped, on: device) else { return }
            show(HUDReadout(kind: .volume, level: clamped, isMuted: false, deviceName: VolumeController.defaultOutputName()))
        case .brightness:
            // No display named: the one the pointer is on, matching the keys.
            guard let display = displayBrightness.displayUnderCursor() else { return }
            adjustBrightness(of: display.id, to: clamped)
        case .keyboardBacklight:
            break
        }
    }

    /// Sets one display's brightness from its own row in the expanded panel.
    public func adjustBrightness(of displayID: CGDirectDisplayID, to level: Double) {
        guard let display = displayBrightness.displays().first(where: { $0.id == displayID }),
              displayBrightness.setLevel(level, on: display)
        else { return }
        persistBrightnessSoon()
        show(HUDReadout(
            kind: .brightness,
            level: displayBrightness.level(of: display) ?? level,
            deviceName: display.name
        ))
    }

    /// Every attached display with its current level, for the expanded panel.
    /// The display under the pointer is marked current — it is the one the keys
    /// and the plain slider act on.
    public func brightnessDisplays() -> [DisplayLevelOption] {
        let cursor = displayBrightness.displayUnderCursor()?.id
        return displayBrightness.displays().map { display in
            DisplayLevelOption(
                id: display.id,
                name: display.name,
                isCurrent: display.id == cursor,
                isBuiltIn: display.isBuiltIn,
                level: displayBrightness.level(of: display) ?? 1
            )
        }
    }

    /// Writes the remembered levels once the user stops moving.
    private func persistBrightnessSoon() {
        brightnessPersistTask?.cancel()
        brightnessPersistTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(400))
            guard let self, !Task.isCancelled else { return }
            self.preferences.externalBrightness = self.displayBrightness.encodedLevels()
        }
    }

    // MARK: - Intercepted keys

    /// Applies the change this app just swallowed.
    ///
    /// Returns whether it was handled. Returning false means the press is
    /// passed through untouched, which is the safe direction — a key that does
    /// what it always did is far better than a key that does nothing.
    private func handle(_ press: MediaKeyDecoder.Press) -> Bool {
        // The key-up must be swallowed if and only if its key-down was. Blanket
        // "handled" on key-up sends macOS an unbalanced down-without-up for
        // every key we deliberately passed through — mute, the backlight keys,
        // brightness on an external display — and those are exactly the keys
        // that latch or auto-repeat when they never see a release.
        guard press.isDown else {
            return swallowedKeyDowns.remove(press.key) != nil
        }

        let handled = applyKeyDown(press.key)
        if handled { swallowedKeyDowns.insert(press.key) }
        return handled
    }

    /// Keys whose press we swallowed, and whose release we therefore owe.
    private var swallowedKeyDowns: Set<MediaKey> = []

    private func applyKeyDown(_ key: MediaKey) -> Bool {
        switch key {
        case .soundUp, .soundDown, .mute:
            return handleVolume(key)
        case .brightnessUp, .brightnessDown:
            return handleBrightness(key)
        case .keyboardBacklightUp, .keyboardBacklightDown:
            // Not applied here: there is no reliable way to *set* the backlight
            // without a header for the private class. Letting the press through
            // means the system changes it and draws its own HUD, which is worth
            // more than a styled HUD over a key that stopped working.
            return false
        }
    }

    private func handleVolume(_ key: MediaKey) -> Bool {
        guard let device = VolumeController.defaultOutputDevice(),
              let current = VolumeController.level(of: device)
        else { return false }

        let wasMuted = VolumeController.isMuted(device)

        if key == .mute {
            // Toggle mute ourselves so the native mute OSD stays suppressed and
            // only Ledge's red pill shows. If the device has no settable mute
            // (some digital outputs), fall through untouched so the key still
            // does whatever it always did.
            VolumeController.noteSelfWrite()
            guard VolumeController.setMuted(!wasMuted, on: device) else { return false }
            show(HUDReadout(kind: .volume, level: current, isMuted: !wasMuted, deviceName: VolumeController.defaultOutputName()))
            return true
        }

        // Volume up/down while muted must unmute first — otherwise setting the
        // scalar changes nothing audible and, with the key swallowed, the volume
        // keys look dead. This is exactly what the native keys do.
        if wasMuted {
            VolumeController.setMuted(false, on: device)
        }

        // min/max pass NaN straight through (`min(max(nan,0),1)` is NaN),
        // and a NaN target would be written into CoreAudio verbatim.
        let step = preferences.hudVolumeStep.isFinite ? preferences.hudVolumeStep : 0.0625
        let target = min(max(current + Double(key.delta) * step, 0), 1)
        VolumeController.noteSelfWrite()
        let didSet = VolumeController.setLevel(target, on: device)

        // Swallow (and show) whenever we could act — either we changed the level
        // or we at least unmuted. Only a device whose volume is genuinely not
        // settable falls through, so the native "locked" indicator can appear
        // rather than the keys silently dying. This is what stops the native
        // sound OSD flickering in intermittently.
        guard didSet || wasMuted else { return false }

        show(HUDReadout(kind: .volume, level: target, isMuted: false, deviceName: VolumeController.defaultOutputName()))
        return true
    }

    /// Brightness keys act on the display the pointer is on, so F1/F2 dim the
    /// external monitor while the cursor is over it and the MacBook's own panel
    /// otherwise — which is what every user of a two-display Mac expects, and
    /// what macOS itself does not do.
    private func handleBrightness(_ key: MediaKey) -> Bool {
        guard let display = displayBrightness.displayUnderCursor(),
              let current = displayBrightness.level(of: display)
        else { return false }

        // Same NaN discipline as volume: a poisoned step would put a NaN in
        // every entry of the display's gamma table — a black screen.
        let step = preferences.hudBrightnessStep.isFinite ? preferences.hudBrightnessStep : 0.0625
        // The gamma floor is not zero, so stepping down on an external display
        // has to clamp there or the last step would appear to do nothing.
        let floor = display.backend == .gamma ? DisplayBrightnessController.gammaFloor : 0
        let target = min(max(current + Double(key.delta) * step, floor), 1)

        guard displayBrightness.setLevel(target, on: display) else { return false }
        if display.backend == .gamma {
            persistBrightnessSoon()
        }

        show(HUDReadout(kind: .brightness, level: target, deviceName: display.name))
        return true
    }

    // MARK: - Presenting

    private func show(_ readout: HUDReadout) {
        presentation.hud = readout
        onReadout(readout)
    }
}
