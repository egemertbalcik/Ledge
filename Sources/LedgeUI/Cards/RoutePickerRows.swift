import Foundation

/// Which output rows an open picker shows while one of them is being dragged.
public enum RoutePickerRows {

    /// Merges a fresh reading of the devices into the rows already on screen,
    /// keeping any row whose level is being dragged right now.
    ///
    /// A row with a pointer down on it owns its place in the list. Removing it
    /// takes its gesture with it — SwiftUI runs `onEnded` only for a gesture
    /// that finishes, so a row pulled out from under a live drag leaves the
    /// drag with no way to end. The card then had to let go of the shell's
    /// latch on the device's behalf, which closes the notch; and the notch
    /// closing under a finger that is still down is worse than a row lingering
    /// a second past the device that owned it.
    ///
    /// Bluetooth and AirPlay make this ordinary rather than exotic: a pair of
    /// headphones drops out of range, or a speaker goes to sleep, and the
    /// device simply stops being listed — often in the middle of the drag that
    /// was reaching for its volume.
    ///
    /// The kept row goes when the pointer lifts, which is a thing that
    /// happens; the picker closing and the card being replaced both clear it
    /// too.
    public static func merging(
        _ fresh: [AudioOutputOption],
        into shown: [AudioOutputOption],
        dragging: Set<UInt32>
    ) -> [AudioOutputOption] {
        guard !dragging.isEmpty else { return fresh }
        let present = Set(fresh.map(\.id))
        let kept = shown.enumerated().filter { _, row in
            dragging.contains(row.id) && !present.contains(row.id)
        }
        guard !kept.isEmpty else { return fresh }

        var rows = fresh
        // Back into the place it had, so a list does not reshuffle under the
        // pointer that is on it.
        for (index, row) in kept {
            rows.insert(row, at: min(index, rows.count))
        }
        return rows
    }
}
