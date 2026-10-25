#ifndef LEDGE_MEDIA_ADAPTER_KIT_H
#define LEDGE_MEDIA_ADAPTER_KIT_H

#import <Foundation/Foundation.h>

/// What the media adapter decides about artwork, apart from the adapter.
///
/// The adapter itself runs inside `/usr/bin/perl` and can only be exercised by
/// something playing on a real Mac. Everything here is a plain function of its
/// arguments, linked into the adapter and into the tests alike, so the parts
/// that decide how many bytes go down the pipe can be checked without either.
///
/// None of it is exported from the dylib perl loads: the adapter links with an
/// export list of one symbol (see Package.swift).

NS_ASSUME_NONNULL_BEGIN

/// The longest side, in pixels, that artwork is sent at. The card shows the
/// cover at thumbnail size and the accent colour is read at 32 px, so nothing
/// on the Ledge side can tell 512 from the original.
static const NSInteger LedgeArtworkMaximumPixels = 512;

/// JPEG or PNG artwork up to this size goes through untouched. Music players
/// send covers of 100 to 200 KB; leaving those exactly as they were keeps the
/// change to the browser's video frames, which are what needed it.
static const NSUInteger LedgeArtworkPassThroughBytes = 256 * 1024;

/// How many artwork ids the adapter remembers having sent. The reader in Ledge
/// keeps at least as many covers, so an id the adapter will not resend is
/// always one Ledge still holds.
static const NSUInteger LedgeArtworkRecentCapacity = 4;

/// The artwork's identity: the first 8 bytes of its SHA-256, as 16 hex
/// characters. Always taken over the *source* bytes, never the thumbnail, so
/// the id names the image the player published and stays stable however it is
/// shrunk.
NSString *ledge_artwork_identifier(NSData *source);

/// The bytes to send for `source`, and their real MIME type.
///
/// - Small JPEG or PNG artwork comes back as it is.
/// - Anything else — a browser's raw TIFF video frame, a huge cover — is
///   scaled so its longest side is at most `maxPixels` and re-encoded: PNG
///   stays PNG, so a transparent cover keeps its transparency, and the rest
///   becomes JPEG. The declared MIME type is never trusted; WebKit labels its
///   uncompressed TIFF frames `image/jpeg`.
///
/// Returns nil when ImageIO cannot read `source` at all. Ledge could not have
/// drawn it either, so sending nothing is the honest answer.
NSData *_Nullable ledge_artwork_for_pipe(
    NSData *source, NSInteger maxPixels, NSString *_Nullable *_Nonnull mime);

/// `recent` with `identifier` moved, or added, to the front, trimmed to
/// `capacity`. Newest first.
///
/// Called once per line the adapter writes that names an artwork id, which is
/// exactly when the reader in Ledge touches its own cache, so the two age
/// their entries in the same order.
NSArray<NSString *> *ledge_artwork_remember(
    NSArray<NSString *> *recent, NSString *identifier, NSUInteger capacity);

/// Whether this poll must ask MediaRemote for the artwork bytes.
///
/// The poll reads the now-playing dictionary every second while something
/// plays, and a browser's video frame is 2 to 3.4 MB of TIFF in every one of
/// those replies. Most polls only need the metadata. The bytes are asked for
/// again when:
///
/// - there is no artwork held, so a cover that arrives a poll late is never
///   missed;
/// - the track changed;
/// - the system's own artwork identifier changed, or it reports none at all
///   and the held one has stopped being fresh (`refreshWithoutSystemID`);
/// - the held artwork is older than `refreshWithSystemID`, as a backstop for
///   a player that changes the image without changing its identifier.
BOOL ledge_artwork_needs_full_read(
    NSString *_Nullable systemID, NSString *_Nullable heldSystemID,
    NSString *_Nullable trackKey, NSString *_Nullable heldTrackKey,
    BOOL holdsArtwork, NSTimeInterval now, NSTimeInterval heldSince,
    NSTimeInterval refreshWithSystemID, NSTimeInterval refreshWithoutSystemID);

/// Whether the artwork-carrying reply describes the same item as the
/// metadata read it is meant to complete.
///
/// The poll reads the metadata without artwork and, when it must, asks for
/// the bytes in a second read. The player can move on in between, and the
/// second reply then carries the next item's cover — which was attached to the
/// first item's title and remembered as that item's image. So every key in
/// `identityKeys` must agree (equal, or absent from both), and the system's own
/// artwork identifier too when both replies carry one. A nil `full` matches
/// nothing.
BOOL ledge_artwork_same_item(
    NSDictionary *metadata, NSDictionary *_Nullable full,
    NSArray<NSString *> *identityKeys, NSString *_Nullable systemArtworkKey);

/// A number the JSON writer will take: `value` when it is a finite number,
/// otherwise 0.
///
/// Players do publish the others. Chromium gives a live stream a duration of
/// +infinity, and AVFoundation's is NaN; `NSJSONSerialization` does not return
/// an error for either, it raises, and the uncaught exception killed perl on
/// every start until Ledge gave up on the adapter for the session.
double ledge_finite_or_zero(id _Nullable value);

/// Whether `value` is the +infinity a player gives a stream with no end.
BOOL ledge_is_endless(id _Nullable value);

/// `object` as one line of JSON, newline included, or nil when it cannot be
/// written. Never raises: a dictionary the writer refuses costs that line,
/// not the process.
NSData *_Nullable ledge_json_line(NSDictionary *object);

NS_ASSUME_NONNULL_END

#endif
