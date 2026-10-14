import Foundation

/// Whether a private Objective-C class may be called at all.
///
/// `PrivateSymbol` does this for C functions: a `dlsym` that comes back nil
/// costs one feature instead of the app. A class reached through the
/// Objective-C runtime needs more than existence, because a selector that is
/// still there with different argument types does not fail to be found — it is
/// called, with the wrong bytes in the registers, and what happens next is not
/// a crash you can catch.
///
/// So the gate is the method's type encoding, compared against one measured on
/// a Mac. `-setBrightness:forKeyboard:` encoded `B28@0:8f16Q20` takes a float
/// and a 64-bit integer and returns a BOOL; if it ever encodes as anything
/// else, the arguments this code would push are not the arguments it wants.
///
/// Pure, and that is the point: the decision is a dictionary comparison, so
/// every way of failing it — a method gone, an encoding changed, a class that
/// is not there at all — can be tested without the framework that would
/// otherwise have to be missing for the test to mean anything.
public enum PrivateMethodGate {

    /// What the gate decided, and why.
    ///
    /// A string in every refusal because the log line is the entire user-facing
    /// consequence: the feature goes quiet, and the only way anybody finds out
    /// which method moved is that this said so.
    public enum Verdict: Equatable, Sendable {
        case ok
        /// The class could not be found. The framework moved, or the class was
        /// renamed or removed.
        case noSuchClass(String)
        /// A method the code needs is not on the class any more.
        case missing(method: String)
        /// It is there, and it is not the same method.
        case changed(method: String, expected: String, found: String)

        public var isOK: Bool { self == .ok }

        /// One line for the log.
        public var reason: String {
            switch self {
            case .ok: "ok"
            case .noSuchClass(let name): "no such class: \(name)"
            case .missing(let method): "\(method) is gone"
            case .changed(let method, let expected, let found):
                "\(method) encodes as \(found), not \(expected)"
            }
        }
    }

    /// - Parameters:
    ///   - className: only for the refusal's text.
    ///   - expected: method name to the type encoding measured on a Mac.
    ///   - found: method name to the encoding the runtime reports now. A
    ///     method absent from this is a method the runtime does not have.
    ///
    /// Every expected method is required. There is no such thing as an
    /// optional one here: each is called on a path that darkens something, and
    /// a path that darkens something it cannot read back or set again is the
    /// one outcome this whole gate exists to prevent.
    ///
    /// Deliberately not version-gated. The macOS major is worth logging and is
    /// worth nothing as a test: encodings that still match on a release nobody
    /// has measured are still the same ABI, and refusing over the version
    /// number alone would switch the feature off every September for no reason
    /// anyone could point at.
    public static func check(className: String,
                             expected: [String: String],
                             found: [String: String]?) -> Verdict {
        guard let found else { return .noSuchClass(className) }
        // Sorted so a class missing two methods always names the same one.
        // A refusal that changes its mind between launches is a refusal
        // nobody can search the log for.
        for method in expected.keys.sorted() {
            let want = expected[method]!
            guard let have = found[method] else { return .missing(method: method) }
            guard have == want else {
                return .changed(method: method, expected: want, found: have)
            }
        }
        return .ok
    }
}
