import AppKit
import CoreGraphics
import Foundation
import LedgeCore
import SwiftUI
import Testing

@testable import LedgeUI

/// Whether a card opens at the height it is going to keep.
///
/// The island opens to a height the shell computes before the card exists,
/// the card then measures itself, and the difference is applied without
/// animation — so any gap between the two is a jump nobody asked for, one or
/// two frames after the card appears.
@Suite("Opening a card", .serialized)
@MainActor
struct CardOpeningTests {

    private static let geometry = NotchGeometry(
        screenSize: CGSize(width: 1470, height: 956),
        notchSize: CGSize(width: 179, height: 32),
        notchCenterX: 735,
        isHardwareNotch: true
    )

    private func host(_ presentation: NotchPresentation) -> NSWindow {
        _ = NSApplication.shared
        NSApplication.shared.setActivationPolicy(.prohibited)
        let size = NotchLayout.panelSize(for: Self.geometry)
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless], backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        window.backgroundColor = .clear
        window.isOpaque = false
        let view = NSHostingView(rootView: NotchOverlayView(
            geometry: Self.geometry,
            preferences: Preferences(store: MemoryPreferenceStore()),
            presentation: presentation
        ).frame(width: size.width, height: size.height))
        view.sizingOptions = []
        window.contentView = view
        window.setContentSize(size)
        window.orderFrontRegardless()
        return window
    }

    private func settle(_ seconds: TimeInterval = 0.3) {
        RunLoop.main.run(until: Date().addingTimeInterval(seconds))
    }

    private func height(_ presentation: NotchPresentation) -> CGFloat {
        presentation.cardSize(
            preferences: Preferences(store: MemoryPreferenceStore()),
            geometry: Self.geometry,
            phase: .expanded
        ).height
    }

    private func notes(_ count: Int) -> Activity {
        Activity(
            id: ActivityID(kind: .notes, source: "notes-\(count)"),
            createdAt: 0,
            payload: .notes(NotesPayload(notes: (0..<count).map {
                NoteSummary(
                    id: "n\($0)", title: "Note \($0)",
                    preview: "Something written down earlier", editedAt: 0
                )
            }))
        )
    }

    private func levelRows(_ count: Int) -> [LevelRow] {
        (0..<count).map { index in
            LevelRow(
                id: "r\(index)",
                kind: index == 0 ? .sound : .display,
                name: index == 0 ? "MacBook Pro Speakers" : "Display \(index)",
                control: .level(0.5),
                canMute: index == 0
            )
        }
    }

    private func levels(_ count: Int) -> Activity {
        let rows = levelRows(count)
        return Activity(
            id: ActivityID(kind: .levels, source: "levels-\(count)"),
            createdAt: 0,
            payload: .levels(LevelsPayload(volume: 0.4, brightness: 0.7, rows: rows))
        )
    }

    /// A display that dims itself in software says so under its row.
    private func notedRows() -> [LevelRow] {
        [
            LevelRow(id: "sound", kind: .sound, name: "MacBook Pro Speakers",
                     control: .level(0.5), canMute: true),
            LevelRow(id: "ext", kind: .display, name: "Studio Display",
                     control: .level(0.5), note: .gamma(floor: 0.2)),
        ]
    }

    private func levelsWithANote() -> Activity {
        let rows = notedRows()
        return Activity(
            id: ActivityID(kind: .levels, source: "levels-noted"),
            createdAt: 0,
            payload: .levels(LevelsPayload(volume: 0.4, brightness: 0.7, rows: rows))
        )
    }

    /// The thing this suite exists for.
    ///
    /// A card that opens at one height and snaps to another a frame later
    /// reads as the opening animation going wrong — and the Notes card was
    /// eighty-eight points out, every first open of every session. The shell
    /// now sizes the island from what the payload is worth, and these cards
    /// are rendered for real to hold that estimate to what they measure.
    @Test("A card opens at the height it settles at")
    func opensWhereItSettles() {
        var cases: [(String, Activity)] = [("notes 0", notes(0))]
        for count in 1...5 { cases.append(("notes \(count)", notes(count))) }
        for count in 1...4 { cases.append(("levels \(count)", levels(count))) }
        cases.append(("levels with a note", levelsWithANote()))

        for (name, activity) in cases {
            let presentation = NotchPresentation()
            presentation.phase = .expanded
            presentation.count = 1
            let window = host(presentation)
            defer { window.orderOut(nil) }

            presentation.selected = activity
            let atOpen = height(presentation)
            settle()
            let settled = height(presentation)
            #expect(
                abs(settled - atOpen) <= 1,
                "\(name) opened at \(atOpen) and settled at \(settled)"
            )
            #expect(presentation.cardContentHeight(for: activity.id) > 0,
                "\(name) never measured itself, so this proves nothing")
        }
    }

    /// The same question asked of the card alone, so a failure above can be
    /// read: these are the numbers `NotchLayout` is written from.
    @Test("What the cards are worth, measured")
    func naturalHeightsMatchTheEstimate() {
        let prefs = Preferences(store: MemoryPreferenceStore())
        let presentation = NotchPresentation()
        presentation.phase = .expanded
        presentation.selected = notes(1)
        let cardWidth = presentation.cardSize(
            preferences: prefs, geometry: Self.geometry, phase: .expanded
        ).width - prefs.gutterRadius * 2

        for count in 0...5 {
            let payload: NotesPayload
            if case .notes(let p) = notes(count).payload { payload = p } else { continue }
            let view = NSHostingView(rootView: NotesCardView(payload: payload)
                .frame(width: cardWidth))
            #expect(
                abs(view.fittingSize.height - NotchLayout.notesContentHeight(noteCount: count)) <= 1,
                "the Notes card with \(count) notes measures \(view.fittingSize.height) and the shell opens it at \(NotchLayout.notesContentHeight(noteCount: count))"
            )
        }

        for count in 1...4 {
            let rows = levelRows(count)
            let view = NSHostingView(rootView: LevelsCardView(
                payload: LevelsPayload(rows: rows), rows: rows
            ).frame(width: cardWidth))
            #expect(
                abs(view.fittingSize.height - NotchLayout.levelsContentHeight(rows)) <= 1,
                "the Levels card with \(count) rows measures \(view.fittingSize.height) and the shell opens it at \(NotchLayout.levelsContentHeight(rows))"
            )
        }

        let noted = notedRows()
        let notedView = NSHostingView(rootView: LevelsCardView(
            payload: LevelsPayload(rows: noted), rows: noted
        ).frame(width: cardWidth))
        #expect(
            abs(notedView.fittingSize.height - NotchLayout.levelsContentHeight(noted)) <= 1,
            "a row carrying a sentence measures \(notedView.fittingSize.height) and the shell opens it at \(NotchLayout.levelsContentHeight(noted))"
        )
    }
}
