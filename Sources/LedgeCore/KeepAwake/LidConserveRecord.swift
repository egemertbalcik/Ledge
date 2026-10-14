import Foundation

/// What Ledge changed on this Mac when the lid came down, and what it has to
/// put back.
///
/// Written *before* anything is applied and cleared only *after* the undo has
/// been confirmed, which is the same order `HelperClaim` uses and for the same
/// reason. The failure the order exists to prevent is not symmetric: a record
/// of a change that never happened costs one pointless restore, while a change
/// with no record is a black screen inside a closed machine that the user
/// cannot fix by any means they would think of — the brightness keys are under
/// the lid, and the panel they would light is the one at zero.
///
/// Entries clear one at a time. A panel that came back is not evidence that a
/// headset did, and clearing the whole record on the first success would be an
/// opinion dressed up as a fact.
public struct LidConserveRecord: Codable, Equatable, Sendable {

    public static let currentVersion = 1

    public var v: Int
    /// `kern.bootsessionuuid`. Kept so a record found at launch can say
    /// whether it belongs to this boot. It is restored either way — nothing
    /// in this boot is relying on a change made in the last one — but the log
    /// line is different, and so is what it means.
    public var boot: String?
    /// The session that was running when this was written. For the log, and
    /// so a record can be told from a newer one.
    public var sessionID: String?
    public var writtenAt: Date

    /// The built-in panel's brightness before Ledge set it to zero.
    ///
    /// The value here is never the one read as the lid closed. See
    /// `LidBrightnessSampler`.
    public var panel: Level?
    /// The keyboard backlight's brightness before Ledge set it to zero.
    ///
    /// Absent whenever the backlight could not be reached, which is the whole
    /// of the rule: nothing is darkened that has no entry here.
    public var keyboard: Level?
    public var audio: Audio?
    public var lowPower: LowPower?

    public init(
        v: Int = LidConserveRecord.currentVersion,
        boot: String? = nil,
        sessionID: String? = nil,
        writtenAt: Date,
        panel: Level? = nil,
        keyboard: Level? = nil,
        audio: Audio? = nil,
        lowPower: LowPower? = nil
    ) {
        self.v = v
        self.boot = boot
        self.sessionID = sessionID
        self.writtenAt = writtenAt
        self.panel = panel
        self.keyboard = keyboard
        self.audio = audio
        self.lowPower = lowPower
    }

    /// A brightness to put back, 0...1.
    public struct Level: Codable, Equatable, Sendable {
        public var level: Double
        public init(level: Double) { self.level = min(max(level, 0), 1) }
    }

    /// One output device, as it was before Ledge muted it.
    ///
    /// The entry belongs to the *device*, not to "the default output". A
    /// restore aimed at whatever happens to be default now would put the
    /// built-in speakers' volume onto a headset, or a headset's onto the
    /// speakers, and the user would have no idea where the number came from.
    public struct Audio: Codable, Equatable, Sendable {
        /// `kAudioDevicePropertyDeviceUID`. Stable across unplugging, across
        /// reboots, and across the device id being reused for something else
        /// — which is why it, and not the `AudioObjectID`, is what is kept.
        public var uid: String
        /// For the log only. A uid says nothing to a human reading one.
        public var name: String?
        /// What the output's level read as when Ledge found it.
        ///
        /// **Nothing restores this, and nothing may.** The lid conserve
        /// changes exactly one thing about an audio device — its mute — so
        /// its level is the user's before, during and after, and writing a
        /// remembered level back is changing a control Ledge never moved.
        ///
        /// It was restored once, and the fix for *how* it was restored is
        /// what showed it should not be: the number here is a display
        /// aggregate, averaged across the channels on a device with no
        /// master, so a stereo output trimmed to 0.2 left and 0.8 right reads
        /// 0.5 — and putting 0.5 back on both channels verifies perfectly
        /// against what was asked for while the user's balance is gone for
        /// good. Journalling the levels per element made that correct and
        /// left the real question standing: Ledge had never touched them.
        ///
        /// So it stays for the log, where a number describing the device as
        /// Ledge found it is worth having when somebody reports a problem.
        /// Nil when the device would not report a level.
        public var volume: Double?
        /// What the device's mute control read as.
        public var muted: Bool
        /// Whether the user's own mute was in force, as far as Ledge knew.
        ///
        /// A physical `muted` cannot carry this. A device sitting at a
        /// clamped logical zero is silent with `userMuted` false, and
        /// restoring it through the user-mute path turned it into a device
        /// the user had muted — the red pill, which they never pressed.
        public var userMuted: Bool?
        /// Whether Ledge was silencing it because its level was zero.
        public var zeroSilence: Bool?
        /// The mute controls Ledge is allowed to touch on this device, chosen
        /// and written down *before* anything was silenced.
        ///
        /// Device elements: the master is `0`, channels are `1`, `2`, and so
        /// on. Kept as plain numbers because this type is pure — but they are
        /// the audio elements, and they are the point of the entry.
        ///
        /// Governance has to be *carried*, not asked for again later. The
        /// capability query ("is the master settable") is answered by the
        /// hardware at the moment it is asked, and three things can make the
        /// second answer differ from the first: a master that reports
        /// settable and then refuses its setter, so the write falls back to
        /// the channels; a failed query, which `AudioObjectIsPropertySettable`
        /// cannot distinguish from an affirmative no; and a device that
        /// genuinely changed. Rediscovering the controls meant observing a
        /// master that had never moved, reading the device as free, and
        /// deleting the undo record with every channel still silent.
        ///
        /// So the plan is journalled first and then obeyed. A write that
        /// would have to fall back to a control outside this list is refused
        /// rather than made: an unrecorded change is the one thing this file
        /// exists to prevent, and a mute that did not happen costs silence
        /// nobody asked for — not silence nobody can undo.
        ///
        /// Nil in a record whose plan is unknown. That retains the
        /// obligation: nothing is certified free, and nothing is written.
        public var governed: [UInt32]?
        /// What the intent ledger's revision for this device read as when the
        /// conserve wrote this entry.
        ///
        /// Only ever compared with a later reading of itself, inside one run
        /// of the app. It exists to answer one question the *reasons*
        /// themselves cannot: did somebody decide something about this output
        /// while the lid was down?
        ///
        /// The conserve mutes the hardware and touches no intent, so the
        /// volume watcher can see that mute and adopt it — an echo of Ledge's
        /// own doing, which the lid coming up is right to correct. A person
        /// reaching for the mute key in the middle produces the same reasons
        /// and means the opposite, and putting the saved ones back over their
        /// decision hands them a silence they asked for and were refused.
        ///
        /// Nil when nothing was readable; meaningless without
        /// `intentIncarnation`.
        public var intentRevision: Int?
        /// Which intent ledger issued `intentRevision`.
        ///
        /// A ledger counts declarations and a count means nothing outside the
        /// ledger that issued it. Persisting the number alone was worse than
        /// not persisting it: a fresh process starts at zero, so every
        /// recovered record compared unequal, every one read as a user
        /// decision, and every one was discharged with the device still
        /// silenced — the exact failure this comparison was built to prevent,
        /// reintroduced by the thing preventing it.
        ///
        /// A record whose incarnation is not the one asking is not
        /// comparable. That is unknown, and unknown is not evidence that
        /// anybody acted, so the restore goes ahead.
        public var intentIncarnation: String?

        public init(uid: String, name: String? = nil, volume: Double? = nil,
                    muted: Bool, userMuted: Bool? = nil, zeroSilence: Bool? = nil,
                    governed: [UInt32]? = nil, intentRevision: Int? = nil,
                    intentIncarnation: String? = nil) {
            self.uid = uid
            self.name = name
            self.volume = volume
            self.muted = muted
            self.userMuted = userMuted
            self.zeroSilence = zeroSilence
            self.governed = governed
            self.intentRevision = intentRevision
            self.intentIncarnation = intentIncarnation
        }
    }

    /// Low Power Mode, as far as this side of the app is entitled to say.
    public struct LowPower: Codable, Equatable, Sendable {
        /// What Low Power Mode read as before Ledge asked for it.
        ///
        /// Nil when the control keeps its own record — the root daemon
        /// journals the prior once per power source, which is finer than this
        /// could ever be. Two records of one setting would disagree for
        /// exactly the user who set Low Power Mode on battery only, and the
        /// coarser of the two cannot even express what they chose. So the
        /// entry stays, because something has to say "Ledge asked for this
        /// and has not taken it back", and the value does not.
        public var wasOn: Bool?
        public init(wasOn: Bool?) { self.wasOn = wasOn }
    }

    /// Nothing is outstanding and the file can go.
    public var isEmpty: Bool {
        panel == nil && keyboard == nil && audio == nil && lowPower == nil
    }
}

/// What to do with one journalled entry when the lid comes up.
///
/// Pure, so every branch can be exercised without a device. The interesting
/// cases are the ones a hinge cannot produce on demand: a headset that was
/// unplugged while the lid was down, and a user who reached for the mute key
/// themselves in the middle.
public enum LidRestore {

    /// What should happen to one audio device.
    public enum Audio: Equatable, Sendable {
        /// Put the mute flag back — and nothing else.
        ///
        /// The mute is the whole of what the conserve changed about this
        /// device, so it is the whole of what the restore may change back.
        /// The level is the user's throughout and is not Ledge's to put
        /// anywhere.
        case put(muted: Bool)
        /// The user unmuted it in the meantime, so the silence Ledge made is
        /// already gone and the state it is in now is the state they chose.
        /// The entry goes; there is nothing left that belongs to Ledge.
        case leaveAlone
        /// The device is not attached. Keep the entry and try again later —
        /// macOS remembers a device's volume across unplugging, so a headset
        /// that comes back comes back muted unless this does.
        case deviceAbsent
    }

    /// - Parameters:
    ///   - isPresent: whether the uid in the entry is attached now.
    ///   - intentChanged: whether somebody has declared something about this
    ///     output's silence *since* the entry was written, and achieved it.
    ///     True means a decision was taken while the lid was down, and a
    ///     decision outranks a record of what things used to be: the device
    ///     is theirs, the hardware stays where they put it, and the entry
    ///     goes. False covers "nothing happened", "we cannot tell" and "they
    ///     tried and the hardware refused" — because neither a question
    ///     nobody can answer nor an attempt that failed is evidence that the
    ///     silence Ledge made has become somebody else's.
    ///   - isMutedNow: what the *governed controls* say — the ones in the
    ///     entry's plan, which are the only ones Ledge silenced. False means
    ///     every one of them is free again. Nil when they will not all say,
    ///     and nil restores: an unreadable mute is not evidence that the user
    ///     did anything, and the entry is the only account of what was there
    ///     before. A control Ledge never wrote answers neither question, and
    ///     asking one is how the record came to be thrown away while the
    ///     device was still silent.
    public static func audio(_ entry: LidConserveRecord.Audio,
                             isPresent: Bool,
                             isMutedNow: Bool?,
                             intentChanged: Bool = false) -> Audio {
        guard isPresent else { return .deviceAbsent }
        // Somebody decided something about this output while the lid was
        // down. Whatever they chose is newer than this record and outranks
        // it — including a mute they asked for, which putting the saved
        // state back would take away from them.
        if intentChanged { return .leaveAlone }
        if isMutedNow == false { return .leaveAlone }
        return .put(muted: entry.muted)
    }

    /// What Low Power Mode should read as once the lid is up.
    ///
    /// - Parameter floorWantsIt: something other than the lid still wants Low
    ///   Power Mode on — another conserve in force, or a floor that would turn
    ///   it on again the moment this turned it off. Turning it off and
    ///   straight back on is a visible flicker in the menu bar for no gain.
    public static func lowPower(_ entry: LidConserveRecord.LowPower,
                                floorWantsIt: Bool) -> Bool {
        // A nil prior is a control that keeps its own, and asking it for
        // `false` is asking it to put back whatever it journalled — which is
        // not the same as off, and is the better answer in every case where
        // they differ.
        (entry.wasOn ?? false) || floorWantsIt
    }
}
