import LedgeCore
import Testing

/// What the shell tells the reducer about resting, from the facts and a feed.
@Suite("Resting hold")
struct RestingHoldTests {

    @Test("A feed alone holds the island, and its going lets it close")
    func feedAlone() {
        var hold = RestingHold()
        #expect(hold.feedChanged(true, farewellRunning: false) == true)
        #expect(hold.feedChanged(false, farewellRunning: false) == false)
        #expect(!hold.holds)
    }

    @Test("A feed beside a fact that already holds says nothing")
    func feedBesideMusic() {
        var hold = RestingHold()
        #expect(hold.factsChanged(true) == true)
        #expect(hold.feedChanged(true, farewellRunning: false) == nil)
        #expect(hold.feedChanged(false, farewellRunning: false) == nil)
        #expect(hold.holds)
    }

    @Test("The facts letting go leave the feed holding")
    func factsLetGoOfAFeed() {
        var hold = RestingHold()
        _ = hold.feedChanged(true, farewellRunning: false)
        _ = hold.factsChanged(true)
        // The paused track's linger runs out: the feed is what is left.
        #expect(hold.factsChanged(false) == true)
    }

    @Test("Every fact is said, changed or not")
    func factsAlwaysSpeak() {
        var hold = RestingHold()
        #expect(hold.factsChanged(false) == false)
        #expect(hold.factsChanged(false) == false)
    }

    /// The farewell borrows the island for a few seconds and hands back
    /// `holds` when it ends. A feed that came or went meanwhile must be in
    /// what it hands back, and must not have spoken over it.
    @Test("Over a farewell nothing is said, and what it hands back is current")
    func overAFarewell() {
        var hold = RestingHold()
        _ = hold.feedChanged(true, farewellRunning: false)
        #expect(hold.feedChanged(false, farewellRunning: true) == nil)
        #expect(!hold.holds, "the farewell would hand back a feed that has gone")

        #expect(hold.feedChanged(true, farewellRunning: true) == nil)
        #expect(hold.holds, "the farewell would close the island on a feed that came")
    }
}
