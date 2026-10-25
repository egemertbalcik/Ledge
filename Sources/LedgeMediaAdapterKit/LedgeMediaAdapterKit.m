// Artwork decisions for the media adapter. See the header for why this lives
// apart from it, and the top of LedgeMediaAdapter.m for why ImageIO is allowed
// into perl.

#import "include/LedgeMediaAdapterKit.h"
#import <CommonCrypto/CommonDigest.h>
#import <CoreGraphics/CoreGraphics.h>
#import <ImageIO/ImageIO.h>

NSString *ledge_artwork_identifier(NSData *source) {
    unsigned char digest[CC_SHA256_DIGEST_LENGTH];
    CC_SHA256(source.bytes, (CC_LONG)source.length, digest);
    NSMutableString *hex = [NSMutableString stringWithCapacity:16];
    for (int i = 0; i < 8; i++) { [hex appendFormat:@"%02x", digest[i]]; }
    return hex;
}

/// What the bytes are, from their first bytes — the only label that cannot lie.
static NSString *SniffedMIME(NSData *data) {
    const unsigned char *bytes = data.bytes;
    if (data.length >= 3 && bytes[0] == 0xFF && bytes[1] == 0xD8 && bytes[2] == 0xFF) {
        return @"image/jpeg";
    }
    static const unsigned char png[8] = { 0x89, 'P', 'N', 'G', 0x0D, 0x0A, 0x1A, 0x0A };
    if (data.length >= 8 && memcmp(bytes, png, 8) == 0) { return @"image/png"; }
    return nil;
}

NSData *ledge_artwork_for_pipe(NSData *source, NSInteger maxPixels, NSString **mime) {
    *mime = nil;
    NSString *sniffed = SniffedMIME(source);
    if (sniffed && source.length <= LedgeArtworkPassThroughBytes) {
        *mime = sniffed;
        return source;
    }

    CGImageSourceRef reader = CGImageSourceCreateWithData((__bridge CFDataRef)source, NULL);
    if (!reader) { return nil; }
    NSDictionary *options = @{
        (__bridge id)kCGImageSourceCreateThumbnailFromImageAlways: @YES,
        (__bridge id)kCGImageSourceCreateThumbnailWithTransform: @YES,
        (__bridge id)kCGImageSourceThumbnailMaxPixelSize: @(maxPixels),
        (__bridge id)kCGImageSourceShouldCacheImmediately: @YES,
    };
    CGImageRef thumbnail = CGImageSourceCreateThumbnailAtIndex(reader, 0, (__bridge CFDictionaryRef)options);
    CFRelease(reader);
    if (!thumbnail) { return nil; }

    BOOL keepPNG = [sniffed isEqualToString:@"image/png"];
    NSMutableData *encoded = [NSMutableData data];
    CGImageDestinationRef writer = CGImageDestinationCreateWithData(
        (__bridge CFMutableDataRef)encoded, keepPNG ? CFSTR("public.png") : CFSTR("public.jpeg"), 1, NULL);
    if (!writer) { CGImageRelease(thumbnail); return nil; }
    // A frame with an alpha channel has to be flattened onto something for
    // JPEG. Black, because black is what the card puts behind the cover.
    CGColorRef black = CGColorCreateGenericRGB(0, 0, 0, 1);
    NSDictionary *properties = @{
        (__bridge id)kCGImageDestinationLossyCompressionQuality: @0.8,
        (__bridge id)kCGImageDestinationBackgroundColor: (__bridge id)black,
    };
    CGImageDestinationAddImage(writer, thumbnail, (__bridge CFDictionaryRef)properties);
    BOOL finished = CGImageDestinationFinalize(writer);
    CFRelease(writer);
    CGColorRelease(black);
    CGImageRelease(thumbnail);
    if (!finished || encoded.length == 0) { return nil; }

    // A cover that was already a JPEG or PNG and does not get smaller is sent
    // as it was: re-encoding it would only have cost quality.
    if (sniffed && encoded.length >= source.length) {
        *mime = sniffed;
        return source;
    }
    *mime = keepPNG ? @"image/png" : @"image/jpeg";
    return encoded;
}

NSArray<NSString *> *ledge_artwork_remember(
    NSArray<NSString *> *recent, NSString *identifier, NSUInteger capacity) {
    NSMutableArray<NSString *> *next = [NSMutableArray arrayWithObject:identifier];
    for (NSString *seen in recent) {
        if (next.count >= capacity) { break; }
        if (![seen isEqualToString:identifier]) { [next addObject:seen]; }
    }
    return next;
}

static BOOL SameString(NSString *a, NSString *b) {
    if (a == b) { return YES; }
    return a && b && [a isEqualToString:b];
}

BOOL ledge_artwork_needs_full_read(
    NSString *systemID, NSString *heldSystemID,
    NSString *trackKey, NSString *heldTrackKey,
    BOOL holdsArtwork, NSTimeInterval now, NSTimeInterval heldSince,
    NSTimeInterval refreshWithSystemID, NSTimeInterval refreshWithoutSystemID) {
    if (!holdsArtwork) { return YES; }
    if (!SameString(trackKey, heldTrackKey)) { return YES; }
    if (!SameString(systemID, heldSystemID)) { return YES; }
    // A clock that went backwards says nothing about freshness; ask.
    NSTimeInterval age = now - heldSince;
    if (age < 0) { return YES; }
    return age >= (systemID ? refreshWithSystemID : refreshWithoutSystemID);
}

double ledge_finite_or_zero(id value) {
    if (![value isKindOfClass:[NSNumber class]]) { return 0; }
    double number = [value doubleValue];
    return isfinite(number) ? number : 0;
}

BOOL ledge_is_endless(id value) {
    if (![value isKindOfClass:[NSNumber class]]) { return NO; }
    double number = [value doubleValue];
    return isinf(number) && number > 0;
}

NSData *ledge_json_line(NSDictionary *object) {
    // Both checks, because each catches what the other cannot: the validity
    // test sees a NaN anywhere in the tree before the writer is asked, and the
    // writer can still refuse what passed it — a string with a lone surrogate
    // comes back as an error, and whatever a future one raises is caught here.
    if (![NSJSONSerialization isValidJSONObject:object]) { return nil; }
    NSData *json = nil;
    @try {
        json = [NSJSONSerialization dataWithJSONObject:object options:0 error:NULL];
    } @catch (NSException *exception) {
        return nil;
    }
    if (!json) { return nil; }
    NSMutableData *line = [json mutableCopy];
    [line appendBytes:"\n" length:1];
    return line;
}

BOOL ledge_artwork_same_item(
    NSDictionary *metadata, NSDictionary *full,
    NSArray<NSString *> *identityKeys, NSString *systemArtworkKey) {
    if (!full) { return NO; }
    for (NSString *key in identityKeys) {
        id a = metadata[key], b = full[key];
        if (a == b) { continue; }
        if (!a || !b || ![a isEqual:b]) { return NO; }
    }
    if (systemArtworkKey) {
        id a = metadata[systemArtworkKey], b = full[systemArtworkKey];
        if (a && b && ![a isEqual:b]) { return NO; }
    }
    return YES;
}
