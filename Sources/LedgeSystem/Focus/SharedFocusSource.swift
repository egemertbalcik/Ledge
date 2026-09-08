import Foundation

/// A second listener on someone else's Focus source.
///
/// Two parts of the app need to know whether a Focus is on: the card, and the
/// rule that keeps the notch quiet during one — and the second has to work
/// whether or not the first is switched on in Settings. They used to answer
/// that by building a source each, which turned out to be the bug behind a
/// Focus card that peeked on and off every few seconds: two watchers, two
/// timers, two filesystem streams, asking macOS the same question a
/// millisecond apart. The answers disagreed, each kept its own idea of the
/// truth, and each announced a change against the other's.
///
/// This is the ordinary fix — one source, many listeners — with the wrinkle
/// that `FocusSource` has no concept of a listener token, so `stopWatching()`
/// on a shared object would silently deafen everyone else. Holding a token and
/// detaching only its own is the whole of this type.
@MainActor
public final class SharedFocusSource: FocusSource {

    private let base: SystemFocusSource
    private var token: UUID?

    public init(_ base: SystemFocusSource) {
        self.base = base
    }

    public var isReadable: Bool { base.isReadable }

    public func current() -> FocusSnapshot? { base.current() }

    public func startWatching(_ onChange: @escaping () -> Void) {
        stopWatching()
        token = base.addObserver(onChange)
    }

    /// Detaches this listener, and only this one. The source goes on watching
    /// for whoever else is listening.
    public func stopWatching() {
        if let token { base.removeObserver(token) }
        token = nil
    }
}
