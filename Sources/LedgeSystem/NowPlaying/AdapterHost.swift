import Foundation

/// A system binary that is allowed to read MediaRemote, and the script that
/// makes it load our helper.
///
/// Since macOS 15.4 `mediaremoted` answers only clients whose bundle
/// identifier begins with `com.apple.` — measured again on 26.4, from a
/// process with no such identifier, while a permitted host looking at the same
/// instant saw a playing track. There is no in-process route: the newer
/// `MRNowPlayingRequest` class API is gated identically, which was worth
/// checking before accepting a subprocess at all.
///
/// So the app borrows a binary Apple ships. It needs three things at once: an
/// identifier under `com.apple.`, a signature with no library validation (or
/// it will refuse to load our dylib), and some way to call a C function. Two
/// binaries on a stock Mac qualify, and the second one matters: both are
/// formally deprecated, and the whole feature rests on one of them existing.
///
/// `/usr/bin/tclsh` is signed `com.tcltk.tclsh` — not `com.apple.`, so it
/// cannot pass the gate. `/usr/bin/osascript` is `com.apple.osascript` and
/// could serve as a third host through the ObjC bridge, which is worth
/// remembering because AppleScript, unlike perl and ruby, is not deprecated.
public struct AdapterHost: Equatable, Sendable {

    /// The interpreter's path.
    public let executable: String

    /// Everything before the script itself.
    public let leadingArguments: [String]

    /// The script that loads the dylib and calls its one exported symbol.
    public let script: String

    /// For logs and diagnostics.
    public let name: String

    public init(executable: String, leadingArguments: [String], script: String, name: String) {
        self.executable = executable
        self.leadingArguments = leadingArguments
        self.script = script
        self.name = name
    }

    public var arguments: [String] { leadingArguments + ["-e", script] }

    /// Whether the interpreter is present and runnable on this Mac.
    public var isPresent: Bool {
        FileManager.default.isExecutableFile(atPath: executable)
    }

    /// Inline rather than a shipped script file: `Process` passes argv
    /// directly, so there is no shell and nothing to quote, and the script
    /// travels inside the code-signed binary instead of being one more
    /// resource to find, seal and keep in sync.
    ///
    /// `-MDynaLoader` is mandatory — `dl_load_file` is not otherwise defined.
    public static let perl = AdapterHost(
        executable: "/usr/bin/perl",
        leadingArguments: ["-MDynaLoader"],
        script: """
            my $lib = $ENV{LEDGE_ADAPTER_DYLIB} or die "LEDGE_ADAPTER_DYLIB unset\\n";
            my $h = DynaLoader::dl_load_file($lib, 0)
                or die "dlopen: " . (DynaLoader::dl_error() // "?") . "\\n";
            my $sym = DynaLoader::dl_find_symbol($h, "ledge_media_adapter_main")
                or die "symbol missing\\n";
            DynaLoader::dl_install_xsub("main::ledge_run", $sym);
            main::ledge_run();
            """,
        name: "perl"
    )

    /// The understudy. Ruby's `fiddle` calls the same exported symbol in the
    /// same dylib, so nothing about the helper changes — only who loads it.
    public static let ruby = AdapterHost(
        executable: "/usr/bin/ruby",
        leadingArguments: [],
        script: """
            require "fiddle"
            lib = ENV["LEDGE_ADAPTER_DYLIB"] or abort "LEDGE_ADAPTER_DYLIB unset"
            handle = Fiddle.dlopen(lib)
            Fiddle::Function.new(handle["ledge_media_adapter_main"], [], Fiddle::TYPE_VOID).call
            """,
        name: "ruby"
    )

    /// In order of preference. Perl first because it is the path this app has
    /// always used and the one every comparable project uses, so it is the
    /// best understood; ruby only when perl has gone.
    public static let all: [AdapterHost] = [.perl, .ruby]

    /// The hosts worth probing on this Mac, honouring an override.
    ///
    /// `LEDGE_ADAPTER_HOST=ruby` forces one, which is how the understudy can
    /// be exercised on a Mac where perl still works — otherwise the fallback
    /// would only ever run on the day it was needed, which is the worst
    /// possible time to find out it does not.
    public static func candidates(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> [AdapterHost] {
        if let forced = environment["LEDGE_ADAPTER_HOST"] {
            return all.filter { $0.name == forced }
        }
        return all.filter(\.isPresent)
    }
}
