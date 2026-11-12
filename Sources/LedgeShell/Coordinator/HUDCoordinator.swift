import AppKit
import CoreAudio
import Foundation
import LedgeCore
import LedgeSystem
import LedgeUI
import os

/// Drives the level HUD.
///
/// Ledge's readout only ever stands *in place of* the system's, never beside
/// it. It is shown when the tap is intercepting (needs Accessibility): the key
/// press is swallowed and this app applies the change itself, so the system
/// never learns the key was pressed and never draws its HUD.
///
/// When the tap is not running — no grant, suppression switched off, no
/// notched display — the keys belong to macOS and so does the readout. Ledge
/// used to draw its own anyway, from CoreAudio and a brightness poll, and the
/// result was two readouts for one key press.
@MainActor
public final class HUDCoordinator {

    private static let log = Logger(subsystem: "com.egemert.ledge", category: "hud")

    private let preferences: Preferences
    private let presentation: NotchPresentation

    private let volume = VolumeController()
    /// Per-display brightness: applies levels, to whichever display the user
    /// means.
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

    /// Whether there is a notch to draw the HUD in.
    ///
    /// Suppressing the system OSD means swallowing the key, and swallowing a
    /// key Ledge cannot answer leaves the user pressing a volume key that does
    /// nothing visible at all — on a clamshell MacBook or a Mac with no notched
    /// display, where `targetScreens()` yields no panel. Brightness is worse
    /// than invisible there: it resolves the external display and scales its
    /// gamma ramp, quietly replacing the monitor's own calibration. Ledge does
    /// not support those Macs, and not supporting them has to mean doing
    /// nothing on them rather than doing that.
    private let hasNotchPanel: () -> Bool

    public init(
        preferences: Preferences,
        presentation: NotchPresentation,
        hasNotchPanel: @escaping () -> Bool = { true }
    ) {
        self.preferences = preferences
        self.presentation = presentation
        self.hasNotchPanel = hasNotchPanel
    }

    public func start() {
        volume.onChange = { [weak self] readout in
            guard let self else { return }
            // Only while intercepting. Otherwise the change came from a key
            // macOS handled and is already drawing its own readout for, and
            // showing ours as well is the double popup this used to produce.
            // While intercepting it also covers changes made elsewhere — the
            // menu bar slider, another app — which macOS draws nothing for.
            guard self.isSuppressing else { return }
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
                // Cancellation during the sleep is the case that matters:
                // `Task.sleep` here is `try?`-swallowed, so a cancelled task
                // wakes and carries straight on. Suppression switched off
                // while this was asleep would have been re-started by a task
                // whose only job was to serve a wish that no longer exists.
                guard !Task.isCancelled, let self else { return }
                // And the wish itself is re-read rather than assumed: the tap
                // may only ever start because it is switched on *now*.
                guard self.preferences.hudEnabled, self.preferences.suppressSystemHUD else { return }
                if MediaKeyInterceptor.isTrusted, self.startTap() {
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
        if DebugSwitches.tracing("hud") {
            let trustPath = (NSHomeDirectory() as NSString).appendingPathComponent(".ledge-hud-trust")
            try? "suppress=\(preferences.suppressSystemHUD) trusted=\(MediaKeyInterceptor.isTrusted)"
                .write(toFile: trustPath, atomically: true, encoding: .utf8)
        }

        guard hasNotchPanel() else {
            // No surface to answer the key with, so leave the key alone and let
            // macOS show its own OSD. Re-checked whenever the panels change, so
            // opening the lid or plugging in the notched display takes it back.
            interceptor.stop()
            onSuppressionChanged?(false)
            trustRetry?.cancel()
            trustRetry = nil
            Self.log.notice("no notched display — leaving the media keys to macOS")
            return
        }

        if preferences.suppressSystemHUD, MediaKeyInterceptor.isTrusted {
            // A failure here is not the end of the attempt. The grant can be
            // seconds old and the system can still refuse the tap; arming the
            // retry on *that* is what the old code missed, because it only
            // ever armed it when the trust check itself said no — and the
            // trust check of the day could not say no.
            if !startTap() { waitForTrust() }
        } else {
            interceptor.stop()
            onSuppressionChanged?(false)
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

    /// Starts the tap and reports whether it took. The only caller of
    /// `interceptor.start` — success cancels the retry, failure is announced.
    @discardableResult
    private func startTap() -> Bool {
        let started = interceptor.start(suppressSystemHUD: true)
        Self.log.notice("native HUD suppression \(started ? "active" : "FAILED to start", privacy: .public)")
        if started {
            trustRetry?.cancel()
            trustRetry = nil
        } else {
            Self.log.error("suppression requested but the tap did not start")
        }
        onSuppressionChanged?(started)
        return started
    }

    /// Told after every attempt to start or stop the tap, with what actually
    /// happened. Settings draws this rather than the preference, so a switch
    /// that is on can never claim a tap that is not running.
    public var onSuppressionChanged: ((Bool) -> Void)?

    public var isSuppressing: Bool { interceptor.isRunning }

    /// Fixes what a drag on the row acts on, at the first touch. Asking again
    /// on every tick meant headphones plugged in mid-drag took the drag with
    /// them, and a pointer sliding onto the next screen started dimming that one.
    public func setRowDragging(_ dragging: Bool) {
        rowDrag = dragging
            ? RowDrag(
                output: VolumeController.defaultOutputDevice(),
                display: brightnessDisplayForTheRow()
            )
            : nil
    }

    private func brightnessDisplayForTheRow() -> CGDirectDisplayID? {
        HUDRowDisplay.target(
            shown: shownBrightnessDisplay,
            underCursor: displayBrightness.displayUnderCursor()?.id,
            available: displayBrightness.displays().filter(\.canDim).map(\.id)
        )
    }

    private struct RowDrag {
        let output: AudioDeviceID?
        let display: CGDirectDisplayID?
    }

    private var rowDrag: RowDrag?

    /// The display the last brightness readout was about, when it named one.
    private var shownBrightnessDisplay: CGDirectDisplayID?

    /// Applies a level set directly from the HUD's draggable bar.
    public func adjust(_ kind: HUDReadout.Kind, to level: Double) {
        let clamped = min(max(level, 0), 1)
        switch kind {
        case .volume:
            guard let device = rowDrag?.output ?? VolumeController.defaultOutputDevice() else { return }
            // One operation: scalar and mute together, in the order that makes
            // no sound, and the readout comes from what the hardware says
            // afterwards rather than from what was asked for.
            guard let result = VolumeController.apply(level: clamped, on: device),
                  result.didSomething
            else { return }
            show(HUDReadout(
                kind: .volume, level: result.shownLevel, isMuted: result.showsMuted,
                deviceName: VolumeController.defaultOutputName()
            ))
        case .brightness:
            guard let display = rowDrag?.display ?? brightnessDisplayForTheRow() else { return }
            adjustBrightness(of: display, to: clamped)
        case .keyboardBacklight:
            break
        }
    }

    /// Sets one display's brightness.
    public func adjustBrightness(of displayID: CGDirectDisplayID, to level: Double) {
        guard let display = displayBrightness.displays().first(where: { $0.id == displayID }),
              displayBrightness.setLevel(level, on: display)
        else { return }
        persistBrightnessSoon()
        show(HUDReadout(
            kind: .brightness,
            level: displayBrightness.level(of: display) ?? level,
            deviceName: display.name
        ), about: display.id)
    }

    /// Every attached display with its current level, for the Levels card.
    /// The display under the pointer is marked current — it is the one the keys
    /// act on.
    public func brightnessDisplays() -> [DisplayLevelOption] {
        let cursor = displayBrightness.displayUnderCursor()?.id
        // Only displays a slider can actually move. A Sidecar iPad and an
        // AirPlay receiver draw their own picture at the far end, so a row for
        // one is a control that answers the drag and changes nothing — the
        // same reason a mirrored secondary is left out of the list.
        return displayBrightness.displays().filter(\.canDim).map { display in
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
            // Brightness readout switched off: the key goes to macOS, which
            // changes the level and draws its own readout, as it always did.
            guard preferences.hudBrightnessEnabled else { return false }
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
              // The *logical* level: stepping from a clamped zero's 0.062
              // would skip the first step on the way back up.
              let current = VolumeController.shownLevel(of: device)
        else { return false }

        if key == .mute {
            // Toggle mute ourselves so the native mute OSD stays suppressed and
            // only Ledge's own readout shows. If the device has no settable mute
            // (some digital outputs), fall through untouched so the key still
            // does whatever it always did.
            return toggleMute(on: device)
        }

        // Volume up/down while muted has to unmute, or the scalar moves and
        // nothing is audible — with the key swallowed, the volume keys look
        // dead. Down to zero has to *mute*, or the output may stay audible at
        // the device's lowest step. Both live in `VolumeWriter` now, in the
        // order that makes no sound on the way.
        //
        // min/max pass NaN straight through (`min(max(nan,0),1)` is NaN),
        // and a NaN target would be written into CoreAudio verbatim.
        let step = preferences.hudVolumeStep.isFinite ? preferences.hudVolumeStep : 0.0625
        let target = min(max(current + Double(key.delta) * step, 0), 1)
        guard let result = VolumeController.apply(level: target, on: device) else { return false }

        // Swallow (and show) whenever we could act — the level moved, or the
        // mute did. Only a device that answered neither falls through, so the
        // native "locked" indicator can appear rather than the keys silently
        // dying. This is what stops the native sound OSD flickering in.
        guard result.didSomething else { return false }

        show(HUDReadout(
            kind: .volume, level: result.shownLevel, isMuted: result.showsMuted,
            deviceName: VolumeController.defaultOutputName()
        ))
        return true
    }

    /// The speaker in the readout: the same thing as the mute key.
    public func toggleMute() {
        guard let device = VolumeController.defaultOutputDevice() else { return }
        toggleMute(on: device)
    }

    /// Toggles the *user's* mute, which is the thing the readout's struck
    /// speaker follows. The device's own property is not the state here: an
    /// output turned all the way down is muted underneath to make it genuinely
    /// silent, and pressing mute down there has nothing left to silence — but
    /// it still has something to say, and the result reports that as a change
    /// even when no write went out.
    @discardableResult
    private func toggleMute(on device: AudioDeviceID) -> Bool {
        let result = VolumeController.apply(muted: !VolumeController.userMuted(device), on: device)
        guard result.didSomething else { return false }
        show(HUDReadout(
            kind: .volume, level: result.shownLevel, isMuted: result.showsMuted,
            deviceName: VolumeController.defaultOutputName()
        ))
        return true
    }

    /// Brightness keys act on the display the pointer is on, so F1/F2 dim the
    /// external monitor while the cursor is over it and the MacBook's own panel
    /// otherwise — which is what every user of a two-display Mac expects, and
    /// what macOS itself does not do.
    private func handleBrightness(_ key: MediaKey) -> Bool {
        guard let display = displayBrightness.displayUnderCursor(),
              // Swallowing the key for a display the ramp cannot reach would
              // make the brightness keys dead while the pointer sat on the
              // iPad. Passed through instead, so whatever macOS does with it
              // still happens.
              display.canDim,
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

        show(HUDReadout(kind: .brightness, level: target, deviceName: display.name), about: display.id)
        return true
    }

    // MARK: - Presenting

    private func show(_ readout: HUDReadout, about display: CGDirectDisplayID? = nil) {
        if readout.kind == .brightness { shownBrightnessDisplay = display }
        presentation.hud = readout
        onReadout(readout)
    }
}
