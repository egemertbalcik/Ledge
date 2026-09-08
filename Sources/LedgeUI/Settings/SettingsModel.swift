import LedgeCore
import Observation

/// What the settings window shows about permissions and providers.
///
/// Same arrangement as `NotchPresentation`: `LedgeUI` owns an observable built
/// only from `LedgeCore` values, and the shell writes it. That is what keeps the
/// view layer from needing to know how a permission is checked or how a
/// provider is constructed.
@MainActor
@Observable
public final class SettingsModel {

    public var permissions: [PermissionRow] = []
    public var providers: [ProviderDescriptor] = []

    /// What the app can currently see playing, and why. Follows a demotion
    /// live, so a settings window left open tells the truth.
    public var mediaSource: MediaSourceStatus = .playersOnly

    /// True when the process that launched the app is a terminal.
    ///
    /// Worth surfacing because macOS credits a permission grant to the
    /// *responsible* process, so anything granted in that state attaches to the
    /// terminal instead — which looks exactly like a denial and is miserable to
    /// diagnose.
    public var isLaunchedFromTerminal = false

    /// Whether the key tap is *actually* running — not whether it was asked
    /// for. The switch below it is a wish; this is what came of the wish, and
    /// a user watching the macOS readout appear over Ledge's own is owed the
    /// difference in writing rather than in a log line nobody reads.
    public var isSuppressingSystemHUD = false

    /// Whether the Focus database folder can be read.
    ///
    /// Observable state rather than a closure the view calls, because a view
    /// only redraws when something it observes changes: the row went on saying
    /// "Not granted" after the folder had been granted, until something else
    /// happened to redraw the pane.
    public var focusFolderGranted = false

    public init() {}

    public func status(of kind: PermissionKind) -> PermissionStatus {
        permissions.first { $0.kind == kind }?.status ?? .notDetermined
    }
}
