// Reads system-wide "now playing" information and writes it to stdout as
// newline-delimited JSON.
//
// This file is never linked into Ledge. It is dlopened by `/usr/bin/perl`, which
// is Apple-signed with the `com.apple.perl` identifier and is therefore entitled
// to talk to `mediaremoted`. Since macOS 15.4 that daemon returns a NULL
// dictionary to everyone else, so a third-party app can only read now-playing
// state by borrowing an entitled host — code loaded into perl inherits its
// entitlement. Verified on macOS 26.4: called directly the dictionary is NULL;
// called through perl it has every key.
//
// Deliberately plain Objective-C. It is injected into a process Apple ships, so
// it must pull in nothing that is not already resident there — libSystem,
// CoreFoundation and Foundation are; the Swift runtime is not.
//
// Exactly one symbol is exported (see `-fvisibility=hidden` in Package.swift):
// a stray export could collide with perl's own and crash someone else's process.

#import <Foundation/Foundation.h>
#import <CommonCrypto/CommonDigest.h>
#import <dlfcn.h>
#import <signal.h>
#import "include/LedgeMediaAdapter.h"

#pragma mark - MediaRemote symbols

typedef void (*MRGetNowPlayingInfo)(dispatch_queue_t, void (^)(NSDictionary *));
typedef void (*MRGetIsPlaying)(dispatch_queue_t, void (^)(BOOL));
typedef void (*MRGetClient)(dispatch_queue_t, void (^)(void *));
typedef CFStringRef (*MRClientString)(void *);
typedef int (*MRClientPID)(void *);
typedef void (*MRRegisterNotifications)(dispatch_queue_t);

static void *gMediaRemote;
static MRGetNowPlayingInfo gGetInfo;
static MRGetIsPlaying gGetIsPlaying;
static MRGetClient gGetClient;
static MRClientString gClientBundleID;
static MRClientString gClientParentBundleID;
static MRClientString gClientDisplayName;
static MRClientPID gClientPID;
static MRRegisterNotifications gRegister;

/// Info-dictionary keys, resolved as *data* symbols: each is a pointer to an
/// NSString, so it must be dereferenced rather than cast.
static NSString *gKeyTitle, *gKeyArtist, *gKeyAlbum, *gKeyDuration, *gKeyElapsed,
    *gKeyTimestamp, *gKeyRate, *gKeyUniqueID, *gKeyArtworkData, *gKeyArtworkMIME,
    *gKeyMediaType,
    *gKeyIsAlwaysLive;
static NSString *gNoteInfoChanged, *gNotePlayingChanged, *gNoteClientChanged;

/// Never force-unwrap a `dlsym` — macOS has already dropped one private symbol
/// this project relied on. Every lookup is checked.
static NSString *MRStringSymbol(const char *name) {
    void *slot = dlsym(gMediaRemote, name);
    if (!slot) { return nil; }
    return (__bridge NSString *)(*(CFStringRef *)slot);
}

static BOOL LoadMediaRemote(NSString **failure) {
    gMediaRemote = dlopen(
        "/System/Library/PrivateFrameworks/MediaRemote.framework/Versions/A/MediaRemote",
        RTLD_LAZY);
    if (!gMediaRemote) { *failure = @"dlopen"; return NO; }

    gGetInfo = (MRGetNowPlayingInfo)dlsym(gMediaRemote, "MRMediaRemoteGetNowPlayingInfo");
    if (!gGetInfo) { *failure = @"MRMediaRemoteGetNowPlayingInfo"; return NO; }

    // Everything below is optional: the adapter degrades rather than failing if
    // a future macOS drops one.
    gGetIsPlaying = (MRGetIsPlaying)dlsym(gMediaRemote, "MRMediaRemoteGetNowPlayingApplicationIsPlaying");
    gGetClient = (MRGetClient)dlsym(gMediaRemote, "MRMediaRemoteGetNowPlayingClient");
    gClientBundleID = (MRClientString)dlsym(gMediaRemote, "MRNowPlayingClientGetBundleIdentifier");
    gClientParentBundleID = (MRClientString)dlsym(gMediaRemote, "MRNowPlayingClientGetParentAppBundleIdentifier");
    gClientDisplayName = (MRClientString)dlsym(gMediaRemote, "MRNowPlayingClientGetDisplayName");
    gClientPID = (MRClientPID)dlsym(gMediaRemote, "MRNowPlayingClientGetProcessIdentifier");
    gRegister = (MRRegisterNotifications)dlsym(gMediaRemote, "MRMediaRemoteRegisterForNowPlayingNotifications");

    gKeyTitle = MRStringSymbol("kMRMediaRemoteNowPlayingInfoTitle");
    gKeyArtist = MRStringSymbol("kMRMediaRemoteNowPlayingInfoArtist");
    gKeyAlbum = MRStringSymbol("kMRMediaRemoteNowPlayingInfoAlbum");
    gKeyDuration = MRStringSymbol("kMRMediaRemoteNowPlayingInfoDuration");
    gKeyElapsed = MRStringSymbol("kMRMediaRemoteNowPlayingInfoElapsedTime");
    gKeyTimestamp = MRStringSymbol("kMRMediaRemoteNowPlayingInfoTimestamp");
    gKeyRate = MRStringSymbol("kMRMediaRemoteNowPlayingInfoPlaybackRate");
    gKeyUniqueID = MRStringSymbol("kMRMediaRemoteNowPlayingInfoUniqueIdentifier");
    gKeyArtworkData = MRStringSymbol("kMRMediaRemoteNowPlayingInfoArtworkData");
    gKeyArtworkMIME = MRStringSymbol("kMRMediaRemoteNowPlayingInfoArtworkMIMEType");
    // Audio or video, straight from the system. It is the only honest way to
    // tell an album from a film — durations and bundle ids are guesswork.
    gKeyMediaType = MRStringSymbol("kMRMediaRemoteNowPlayingInfoMediaType");
    // Live streams have no end to count down to. The system says so itself
    // rather than leaving it to be guessed from a missing duration.
    gKeyIsAlwaysLive = MRStringSymbol("kMRMediaRemoteNowPlayingInfoIsAlwaysLive");

    gNoteInfoChanged = MRStringSymbol("kMRMediaRemoteNowPlayingInfoDidChangeNotification");
    gNotePlayingChanged = MRStringSymbol("kMRMediaRemoteNowPlayingApplicationIsPlayingDidChangeNotification");
    gNoteClientChanged = MRStringSymbol("kMRMediaRemoteNowPlayingApplicationClientStateDidChange");
    return YES;
}

#pragma mark - Output

static BOOL gIncludeArtwork = YES;
static NSString *gLastArtworkID = nil;

static void EmitLine(NSDictionary *object) {
    NSError *error = nil;
    NSData *json = [NSJSONSerialization dataWithJSONObject:object options:0 error:&error];
    if (!json) { return; }
    fwrite(json.bytes, 1, json.length, stdout);
    fputc('\n', stdout);
    fflush(stdout);
}

static double NumberOrZero(id value);

/// The last payload sent, minus the fields that move on their own.
static NSDictionary *gLastSent = nil;

/// Whether this payload says anything the last one did not.
///
/// The position advances on every reading and the reader extrapolates between
/// them, so it is not news by itself — but a jump the previous line could not
/// have led to is a seek, and that is. Everything else is a plain comparison.
static BOOL IsNews(NSDictionary *payload) {
    if (!gLastSent) { return YES; }

    NSArray<NSString *> *keys = @[
        @"playing", @"title", @"artist", @"album", @"bundleID",
        @"trackID", @"duration", @"artworkID", @"live", @"mediaType",
    ];
    for (NSString *key in keys) {
        id a = gLastSent[key], b = payload[key];
        if (a == b) { continue; }
        if (!a || !b || ![a isEqual:b]) { return YES; }
    }

    // Position is judged against the stamp it was measured at, not against
    // the wall clock. Spotify republishes `elapsed` only when something
    // happens: read on a timer it sits still while the track plays, and a
    // wall-clock comparison called every one of those readings a seek — a line
    // down the pipe every few seconds saying nothing had changed.
    double wasStamp = NumberOrZero(gLastSent[@"elapsedAt"]);
    double nowStamp = NumberOrZero(payload[@"elapsedAt"]);
    double was = NumberOrZero(gLastSent[@"elapsed"]);
    double is = NumberOrZero(payload[@"elapsed"]);

    if (wasStamp > 0 && nowStamp > 0) {
        // The same measurement, re-read: nothing to say.
        if (fabs(nowStamp - wasStamp) < 0.001 && fabs(is - was) < 0.001) { return NO; }
        BOOL playing = [payload[@"playing"] isKindOfClass:[NSNumber class]]
            && [payload[@"playing"] boolValue];
        double expected = playing ? was + (nowStamp - wasStamp) : was;
        return fabs(is - expected) > 2.5;
    }

    // No stamp to work from — fall back to the wall clock.
    double wasAt = NumberOrZero(gLastSent[@"t"]);
    double nowAt = NumberOrZero(payload[@"t"]);
    BOOL playing = [payload[@"playing"] isKindOfClass:[NSNumber class]]
        && [payload[@"playing"] boolValue];
    double expected = playing ? was + (nowAt - wasAt) : was;
    return fabs(is - expected) > 2.5;
}

/// Emits only when something changed. The poll below runs every second or two;
/// without this it would push a line — and, on a track change, a cover — down
/// the pipe on every tick.
static void EmitIfNews(NSDictionary *payload) {
    if (!IsNews(payload)) { return; }
    gLastSent = payload;
    EmitLine(payload);
}

static NSString *SHA256Prefix(NSData *data) {
    unsigned char digest[CC_SHA256_DIGEST_LENGTH];
    CC_SHA256(data.bytes, (CC_LONG)data.length, digest);
    NSMutableString *hex = [NSMutableString stringWithCapacity:16];
    for (int i = 0; i < 8; i++) { [hex appendFormat:@"%02x", digest[i]]; }
    return hex;
}

static double NumberOrZero(id value) {
    return [value isKindOfClass:[NSNumber class]] ? [value doubleValue] : 0;
}

/// Builds one payload line from the three async answers.
static NSDictionary *BuildPayload(NSDictionary *info, BOOL playing, NSDictionary *client) {
    NSMutableDictionary *out = [NSMutableDictionary dictionary];
    out[@"adapter"] = @1;
    out[@"ok"] = @YES;
    out[@"kind"] = @"now";
    out[@"t"] = @([[NSDate date] timeIntervalSince1970]);

    // No dictionary, or one with no title at all, means nothing is loaded.
    // Reported explicitly so the reader can tell "idle" from "wedged".
    if (info.count == 0 || (gKeyTitle && !info[gKeyTitle])) {
        out[@"playing"] = [NSNull null];
        return out;
    }

    out[@"playing"] = @(playing);
    if (gKeyTitle && info[gKeyTitle]) out[@"title"] = info[gKeyTitle];
    if (gKeyArtist && info[gKeyArtist]) out[@"artist"] = info[gKeyArtist];
    if (gKeyAlbum && info[gKeyAlbum]) out[@"album"] = info[gKeyAlbum];
    if (gKeyDuration) out[@"duration"] = @(NumberOrZero(info[gKeyDuration]));
    if (gKeyElapsed) out[@"elapsed"] = @(NumberOrZero(info[gKeyElapsed]));
    if (gKeyRate) out[@"rate"] = @(NumberOrZero(info[gKeyRate]));
    if (gKeyUniqueID && info[gKeyUniqueID]) {
        out[@"trackID"] = [NSString stringWithFormat:@"%@", info[gKeyUniqueID]];
    }
    if (gKeyIsAlwaysLive && info[gKeyIsAlwaysLive]) {
        out[@"live"] = @([info[gKeyIsAlwaysLive] boolValue]);
    }
    if (gKeyMediaType && info[gKeyMediaType]) {
        // The values read kMRMediaRemoteNowPlayingInfoTypeAudio / …TypeVideo;
        // only the tail matters, and anything unrecognised stays "unknown" so
        // the Swift side can decide what to do with a shape we have not seen.
        NSString *type = [NSString stringWithFormat:@"%@", info[gKeyMediaType]];
        if ([type hasSuffix:@"Video"]) {
            out[@"mediaType"] = @"video";
        } else if ([type hasSuffix:@"Audio"]) {
            out[@"mediaType"] = @"audio";
        } else {
            out[@"mediaType"] = @"unknown";
        }
    }

    // Elapsed time only means something together with the instant it was
    // measured; the reader extrapolates from the pair so the scrub bar keeps
    // moving between updates.
    if (gKeyTimestamp) {
        id stamp = info[gKeyTimestamp];
        if ([stamp isKindOfClass:[NSDate class]]) {
            out[@"elapsedAt"] = @([(NSDate *)stamp timeIntervalSince1970]);
        }
    }

    if (client) [out addEntriesFromDictionary:client];

    if (gKeyArtworkData) {
        NSData *art = info[gKeyArtworkData];
        if ([art isKindOfClass:[NSData class]] && art.length > 0 && art.length < 4 * 1024 * 1024) {
            NSString *identifier = SHA256Prefix(art);
            out[@"artworkID"] = identifier;
            if (gKeyArtworkMIME && info[gKeyArtworkMIME]) {
                out[@"artworkMIME"] = info[gKeyArtworkMIME];
            }
            // Cover art is hundreds of kilobytes. Sending it on every update
            // would be absurd; once per track is free.
            if (gIncludeArtwork && ![identifier isEqualToString:gLastArtworkID]) {
                out[@"artwork"] = [art base64EncodedStringWithOptions:0];
                gLastArtworkID = identifier;
            }
        }
    }
    return out;
}

#pragma mark - Reading

static dispatch_queue_t gQueue;

/// The queue MediaRemote answers on. It must not be `gQueue`: `Refresh()`
/// runs *on* `gQueue` whenever a notification or the debounce timer drives it,
/// and it blocks that queue in `dispatch_group_wait` — so replies dispatched
/// back onto the same serial queue could not run until the wait had already
/// timed out. Every change-driven refresh then stalled 1.5 s and reported
/// "nothing playing"; only the start-up call from the main thread ever saw a
/// track, and browser media vanished on its first play/pause. Replies land
/// here instead, and the wait completes in milliseconds.
static dispatch_queue_t gReplyQueue;

/// Fans the three getters out together and joins with a deadline, so one
/// unanswered callback cannot wedge the helper.
static void Refresh(void) {
    dispatch_group_t group = dispatch_group_create();
    __block NSDictionary *info = nil;
    __block BOOL playing = NO;
    __block NSMutableDictionary *client = nil;

    dispatch_group_enter(group);
    gGetInfo(gReplyQueue, ^(NSDictionary *result) {
        info = [result copy];
        dispatch_group_leave(group);
    });

    if (gGetIsPlaying) {
        dispatch_group_enter(group);
        gGetIsPlaying(gReplyQueue, ^(BOOL value) {
            playing = value;
            dispatch_group_leave(group);
        });
    }

    if (gGetClient && gClientBundleID) {
        dispatch_group_enter(group);
        gGetClient(gReplyQueue, ^(void *handle) {
            if (handle) {
                client = [NSMutableDictionary dictionary];
                CFStringRef bundleID = gClientBundleID(handle);
                if (bundleID) client[@"bundleID"] = (__bridge NSString *)bundleID;
                if (gClientParentBundleID) {
                    CFStringRef parent = gClientParentBundleID(handle);
                    if (parent) client[@"parentBundleID"] = (__bridge NSString *)parent;
                }
                if (gClientDisplayName) {
                    CFStringRef name = gClientDisplayName(handle);
                    if (name) client[@"displayName"] = (__bridge NSString *)name;
                }
                if (gClientPID) client[@"pid"] = @(gClientPID(handle));
            }
            dispatch_group_leave(group);
        });
    }

    // On a timeout the late replies may still be writing the captured
    // variables from the reply queue; reading them here would race. Emit the
    // honest "nothing" and let the stragglers land unobserved.
    if (dispatch_group_wait(group, dispatch_time(DISPATCH_TIME_NOW, 1500 * NSEC_PER_MSEC)) != 0) {
        EmitIfNews(BuildPayload(nil, NO, nil));
        return;
    }
    EmitIfNews(BuildPayload(info, playing, client));
}

/// Collapses the burst of notifications a single track change produces.
static dispatch_source_t gDebounce;

static void ScheduleRefresh(void) {
    if (gDebounce) { dispatch_source_cancel(gDebounce); gDebounce = nil; }
    gDebounce = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, gQueue);
    dispatch_source_set_timer(
        gDebounce,
        dispatch_time(DISPATCH_TIME_NOW, 60 * NSEC_PER_MSEC),
        DISPATCH_TIME_FOREVER, 10 * NSEC_PER_MSEC);
    dispatch_source_set_event_handler(gDebounce, ^{
        dispatch_source_cancel(gDebounce);
        gDebounce = nil;
        Refresh();
    });
    dispatch_resume(gDebounce);
}

#pragma mark - Lifetime

/// Ledge holds the write end of our stdin. When Ledge dies — including a SIGKILL
/// from `make run`, which runs no cleanup — the pipe closes and we exit. This is
/// what actually prevents orphaned perl processes; a `terminate()` from the
/// parent cannot be relied on.
// Held in statics on purpose. A dispatch source is an ObjC object under ARC:
// left in a local it is released the moment the function returns, and a
// deallocated source never fires. That failure is silent — the helper simply
// outlives its parent for ever.
static dispatch_source_t gStdinSource;
static dispatch_source_t gParentSource;
static dispatch_source_t gHeartbeat;

static void WatchParent(void) {
    gStdinSource = dispatch_source_create(
        DISPATCH_SOURCE_TYPE_READ, STDIN_FILENO, 0, gQueue);
    dispatch_source_set_event_handler(gStdinSource, ^{
        char buffer[256];
        ssize_t count = read(STDIN_FILENO, buffer, sizeof(buffer));
        if (count <= 0) { exit(0); }
    });
    dispatch_resume(gStdinSource);

    pid_t parent = getppid();
    if (parent > 1) {
        gParentSource = dispatch_source_create(
            DISPATCH_SOURCE_TYPE_PROC, parent, DISPATCH_PROC_EXIT, gQueue);
        dispatch_source_set_event_handler(gParentSource, ^{ exit(0); });
        dispatch_resume(gParentSource);
    }
}

/// Asks MediaRemote on a timer, because its notifications cannot be relied on.
///
/// Measured on macOS 26.4: an unentitled host registers for the three
/// now-playing notifications, every symbol resolves, and not one notification
/// is ever delivered — the helper read the world once at startup and then went
/// deaf while music played and paused in front of it. Reads keep working; only
/// the change events are gone. So the reads are what this leans on.
///
/// A second while something plays, three while nothing does. `EmitIfNews`
/// keeps the pipe quiet between real changes, so the cost is one MediaRemote
/// round trip, not a line of JSON.
static dispatch_source_t gPoll;
static NSTimeInterval gPollInterval = 0;

static void SchedulePoll(NSTimeInterval seconds);

static NSTimeInterval PollIntervalNow(void) {
    BOOL playing = [gLastSent[@"playing"] isKindOfClass:[NSNumber class]]
        && [gLastSent[@"playing"] boolValue];
    return playing ? 1.0 : 3.0;
}

static void StartPoll(void) {
    SchedulePoll(PollIntervalNow());
}

static void SchedulePoll(NSTimeInterval seconds) {
    if (gPoll) { dispatch_source_cancel(gPoll); gPoll = nil; }
    gPollInterval = seconds;
    gPoll = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, gQueue);
    dispatch_source_set_timer(gPoll,
                              dispatch_time(DISPATCH_TIME_NOW, (int64_t)(seconds * NSEC_PER_SEC)),
                              (uint64_t)(seconds * NSEC_PER_SEC),
                              NSEC_PER_SEC / 4);
    dispatch_source_set_event_handler(gPoll, ^{
        Refresh();
        // Playing and paused deserve different attention, and which one this
        // is only becomes clear after a reading.
        NSTimeInterval wanted = PollIntervalNow();
        if (fabs(wanted - gPollInterval) > 0.01) { SchedulePoll(wanted); }
    });
    dispatch_resume(gPoll);
}

/// A line every 30s even when nothing changes, so the reader can tell a quiet
/// system from a wedged helper.
static void StartHeartbeat(void) {
    gHeartbeat = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, gQueue);
    dispatch_source_set_timer(gHeartbeat,
                              dispatch_time(DISPATCH_TIME_NOW, 30 * NSEC_PER_SEC),
                              30 * NSEC_PER_SEC, NSEC_PER_SEC);
    dispatch_source_set_event_handler(gHeartbeat, ^{
        EmitLine(@{ @"adapter": @1, @"ok": @YES, @"kind": @"heartbeat",
                    @"t": @([[NSDate date] timeIntervalSince1970]) });
    });
    dispatch_resume(gHeartbeat);
}

#pragma mark - Entry point

void ledge_media_adapter_main(void) {
    @autoreleasepool {
        // A write to a closed stdout must kill us rather than raise EPIPE for
        // ever; line buffering keeps each JSON object atomic in practice.
        signal(SIGPIPE, SIG_DFL);
        setvbuf(stdout, NULL, _IOLBF, 0);

        NSDictionary *env = [[NSProcessInfo processInfo] environment];
        NSString *mode = env[@"LEDGE_ADAPTER_MODE"] ?: @"get";
        gIncludeArtwork = ![env[@"LEDGE_ADAPTER_ARTWORK"] isEqualToString:@"0"];

        NSString *failure = nil;
        if (!LoadMediaRemote(&failure)) {
            EmitLine(@{ @"adapter": @1, @"ok": @NO, @"error": failure ?: @"unknown" });
            exit(2);
        }

        gQueue = dispatch_queue_create("com.egemert.ledge.adapter", DISPATCH_QUEUE_SERIAL);
        gReplyQueue = dispatch_queue_create("com.egemert.ledge.adapter.reply", DISPATCH_QUEUE_SERIAL);

        // Emitted before any MediaRemote round-trip, so a probe can confirm
        // dlopen and symbol resolution independently of whether anything is
        // actually playing.
        EmitLine(@{ @"adapter": @1, @"ok": @YES, @"kind": @"hello", @"pid": @(getpid()) });

        if ([mode isEqualToString:@"get"]) {
            Refresh();
            exit(0);
        }

        WatchParent();
        StartHeartbeat();
        StartPoll();

        if (gRegister) { gRegister(gQueue); }

        NSNotificationCenter *center = [NSNotificationCenter defaultCenter];
        NSArray<NSString *> *names = @[
            gNoteInfoChanged ?: @"", gNotePlayingChanged ?: @"", gNoteClientChanged ?: @"",
        ];
        NSUInteger installed = 0;
        for (NSString *name in names) {
            if (name.length == 0) { continue; }
            [center addObserverForName:name object:nil queue:nil
                            usingBlock:^(NSNotification *note) { ScheduleRefresh(); }];
            installed += 1;
        }
        // Zero observers used to be silent: the symbols are looked up with
        // `dlsym` and skipped when missing, so a renamed constant would have
        // left the helper deaf with nothing in the log to say so.
        EmitLine(@{ @"adapter": @1, @"ok": @YES, @"kind": @"observers",
                    @"count": @(installed) });

        Refresh();
        CFRunLoopRun();
    }
}
