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

    public init() {}

    public func status(of kind: PermissionKind) -> PermissionStatus {
        permissions.first { $0.kind == kind }?.status ?? .notDetermined
    }
}
