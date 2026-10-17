import Foundation

/// The welcome tour's four steps.
///
/// Two of them are done rather than read: hovering the notch and dropping a
/// file on it are the only two facts about Ledge that nothing else can teach,
/// because the notch says nothing about itself until it is touched. The other
/// two are read: what Ledge may ask for, and what it does with it.
public enum TourStep: Int, CaseIterable, Equatable, Sendable {
    case hover
    case drop
    case permissions
    case done

    /// The word in the footer. The steps are a real sequence, so they are
    /// numbered; dots that said only "page three of five" are gone.
    public var name: String {
        switch self {
        case .hover: "Hover"
        case .drop: "Drop"
        case .permissions: "Permissions"
        case .done: "Done"
        }
    }

    public var number: Int { rawValue + 1 }

    public var next: TourStep? { TourStep(rawValue: rawValue + 1) }
    public var previous: TourStep? { TourStep(rawValue: rawValue - 1) }
}

/// Something the real notch did, told to the tour.
///
/// Plain data in `LedgeCore` so `LedgeUI` can take it: the tour watches the
/// notch it is teaching, and says when it saw you. It never *waits* — a step
/// that would not move until you hovered traps anybody with VoiceOver, a
/// broken trackpad, or Ledge on another display. Continue is live from the
/// first second.
public enum TourSignal: Equatable, Sendable {
    case opened
    case closed
    case fileDropped
}

/// What the two do-it steps have seen the real notch do.
///
/// Its own type so the rule can be tested: a close that nobody opened is the
/// notch finishing something of its own — an announcement retiring — and
/// crediting it to the reader would tell them they did something they did not
/// do.
public struct TourProgress: Equatable, Sendable {

    public private(set) var hasOpened = false
    public private(set) var hasClosedAgain = false
    public private(set) var hasTakenAFile = false

    public init() {}

    public mutating func saw(_ signal: TourSignal) {
        switch signal {
        case .opened:
            hasOpened = true
        case .closed:
            if hasOpened { hasClosedAgain = true }
        case .fileDropped:
            hasTakenAFile = true
        }
    }

    /// Hovering is only taught by the pair: it opened when you arrived, and
    /// closed when you left.
    public var hoverIsDone: Bool { hasClosedAgain }

    public var dropIsDone: Bool { hasTakenAFile }
}

/// Every word the tour says.
///
/// Here rather than in the view for the usual reason — the tests read them,
/// and three of the old tour's sentences were wrong about the app for months
/// because nothing but the view had ever seen them.
public enum TourCopy {

    public static let title = "Welcome to Ledge"

    /// A second visit is a lookup — "how did I get Accessibility back?" — so
    /// it says what it is instead of welcoming somebody who has been here for
    /// a week.
    public static let titleAgain = "How Ledge Works"

    public static let back = "Back"
    public static let next = "Continue"
    public static let done = "Done"

    /// Under the window, pointing up at the thing being taught.
    public static let pointer = "The notch is right above this window."
    public static let pointerNoNotch = "Ledge draws its notch right above this window."

    // MARK: Hover

    public static let hoverTitle = "Ledge lives in the notch"
    public static let hoverBody = """
        When something happens on your Mac, like AirPods connecting, a charger \
        going in or a timer finishing, the notch widens for a moment and then \
        closes again.
        """
    public static let hoverBodyNoNotch = """
        This Mac has no notch, so Ledge draws one at the top of the screen. When \
        something happens, like AirPods connecting, a charger going in or a timer \
        finishing, it widens for a moment and then closes again.
        """
    public static let hoverAsk = "Try it: move the pointer onto the notch, then away."
    public static let hoverAskNote = "It opens when you arrive and closes when you leave."
    public static let hoverWaiting = "Waiting for the pointer…"
    public static let hoverDone =
        "It opened when you arrived and closed when you left. That's how it always works."
    public static let hoverAgain = "Try it any time. Nothing here waits for you."
    public static let hoverClick = "Click it to keep it open while you use it."
    public static let hoverSwipe =
        "Swipe sideways on the trackpad to move between cards when there's more than one."

    // MARK: Drop

    public static let dropTitle = "Drop a file on it"
    public static let dropBody = """
        Drag a file onto the notch and it waits on the shelf until you drag it out \
        where you need it. New screenshots land there too.
        """
    public static let dropAsk = "Try it: drag any file from your desktop onto the notch."
    public static let dropAskNote = "The notch widens to show it's ready to take it."
    public static let dropWaiting = "Waiting for a file…"
    public static let dropDone =
        "It's on the shelf. Hover the notch to see it, and drag it out when you need it."

    // MARK: Permissions

    public static let permissionsTitle = "What Ledge may use"
    public static let permissionsBody = """
        All optional. Each one turns on one thing, and Ledge works without any of \
        them. Nothing is asked for until you press its button.
        """
    public static let permissionsFooter = """
        Works without asking: battery, timers, sound and brightness levels, the \
        shelf, and weather for a city you type in Settings.
        """

    /// Said beside the Calendar row after a grant, because switching the card
    /// on is the reason to allow it.
    public static let calendarCardIsOn = "The Calendar card is on."

    // MARK: Done

    public static let doneTitle = "That's Ledge"
    public static let doneHover = "Hover the notch to open it. Leave, and it closes."
    public static let doneDrop = "Drop files on it to keep them close."
    public static let doneSettings = """
        To change anything, open Ledge again from Applications or Spotlight. \
        Settings opens.
        """

    public static let privacyTitle = "What it does with your things"

    /// Corrected. The page that exists to be trusted used to say there was no
    /// capture code in Ledge, while the Calendar card ran a capture session;
    /// that Calendar was read for titles and times, while it also reads each
    /// event's location, URL and notes to find a meeting link; and that
    /// settings and shelf paths were all that was written, while notes, the
    /// device catalogue, the Keep Awake journal and the helper's claims are
    /// written too.
    public static let privacyCamera = """
        The camera is used only for the mirror in the Calendar card, while you have \
        it open. Nothing it sees is recorded or saved.
        """
    public static let privacyCalendar = """
        Calendar events are read on this Mac to show the next one and find its \
        meeting link.
        """
    public static let privacyNetwork = """
        Over the network: weather from Open-Meteo with your position rounded to \
        about a kilometre, place names from Apple, cover art from the player, and \
        update checks from GitHub.
        """
    public static let privacyDisk = """
        Kept on this Mac: settings, the shelf's list, your notes, device battery \
        history and the Keep Awake log.
        """

    public static let chooseCards = "Choose Cards…"
    public static let readSource = "Read the Source…"

    // MARK: The notch's own lines

    /// The card the notch plays while the Hover step is up.
    public static let hello = (title: "This is Ledge", detail: "Move away and I'll close.")

    /// After the tour, once.
    public static let welcome = (title: "You're all set", detail: "Hover me any time")
}
