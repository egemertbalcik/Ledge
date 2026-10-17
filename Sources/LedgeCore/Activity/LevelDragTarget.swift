/// Which device a level gesture is writing to.
///
/// The rule it exists for: a drag holds the device it started on for the whole
/// gesture, and everything else follows the system. Resolving "the current
/// output" on every tick instead meant plugging in headphones mid-drag moved
/// the drag to them — the number on screen went on moving, so there was
/// nothing to see, and the device being changed was not the one being looked
/// at.
///
/// Outside the drag the opposite is true: an output that changes under an open
/// card must bring its own level along, because the card is now about that
/// device whether or not anybody touched it.
public struct LevelDragTarget<Device: Equatable>: Equatable {

    private var held: Device?

    public init() {}

    /// A gesture started. The device it started on is the device it owns.
    public mutating func began(on device: Device?) { held = device }

    /// The gesture ended, and the card follows the system again.
    public mutating func ended() { held = nil }

    public var isDragging: Bool { held != nil }

    /// Which device a write goes to, given what the system currently says.
    ///
    /// The held one while a drag is in flight, and the system's otherwise.
    /// Never a held device the system has stopped reporting: unplugging the
    /// output mid-drag leaves nothing to write to, and writing to a device
    /// that is gone is not better than not writing.
    public func device(current: Device?, isStillPresent: (Device) -> Bool) -> Device? {
        guard let held else { return current }
        return isStillPresent(held) ? held : current
    }
}
