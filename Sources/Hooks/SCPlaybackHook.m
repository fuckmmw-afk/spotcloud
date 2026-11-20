// Plays SoundCloud tracks through Spotify's own player, as local files.
//
// Every player command Swift code sends goes through Spotify's Esperanto transports (Cosmos and the C++
// bridge). A command whose payload names a SoundCloud track's spotify:local: URI is looked at here:
//   * Play / PreparePlay / SkipToTrack: when the track it starts on (PreparePlayOptions.skip_to, else the
//     only SC track) has no file yet, the command is held: the track is downloaded, Spotify's local files
//     are rescanned until it shows up, its real URI replaces SpotCloud's in the payload, then the command
//     goes on. Spotify gets a cancellable lifetime at once, as it would from the transport.
//   * Every other command and every ContextPlayer state update: the next SC tracks are prefetched.
// The local files switch and the Documents source are turned on once.
#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/message.h>
#import <objc/runtime.h>
#import "../Core/SCFeatures.h"
#import "../Core/SCLog.h"
#import "../Core/SCProto.h"
#import "../Core/SCSwizzle.h"
#import "../Library/SCEsperanto.h"
#import "../Library/SCLibrary.h"
#import "../Media/SCDownloader.h"

void SCToast(NSString *text);
const char *SCBlockSignature(id block);

static NSString *const kLocalPrefix = @"spotify:local:";
static dispatch_queue_t gQueue;

#pragma mark - which SC tracks a payload names

static NSArray<SCEntry *> *entriesIn(NSData *payload) {
    if (![payload isKindOfClass:NSData.class] || !payload.length) return @[];
    static NSData *needle;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ needle = [kLocalPrefix dataUsingEncoding:NSUTF8StringEncoding]; });
    if ([payload rangeOfData:needle options:0 range:NSMakeRange(0, payload.length)].location == NSNotFound) return @[];
    NSMutableArray *entries = [NSMutableArray array];
    for (NSString *uri in SCProtoStringsWithPrefix(payload, kLocalPrefix)) {
        SCEntry *e = [SCLibrary.shared entryForURI:uri];
        if (e && ![entries containsObject:e]) [entries addObject:e];
    }
    return entries;
}

static NSData *fieldValue(NSData *message, uint32_t number) {
    for (SCProtoField *f in SCProtoParse(message ?: [NSData data]) ?: @[]) if (f.number == number && f.wireType == 2) return f.value;
    return nil;
}

// PlayRequest.prepare_play_request(1).options(2).skip_to(3), or PreparePlayRequest.options(2).skip_to(3).
static SCEntry *startTrack(NSString *method, NSData *payload, NSArray<SCEntry *> *entries) {
    NSData *prepare = [method isEqualToString:@"Play"] ? fieldValue(payload, 1) : payload;
    NSData *skipTo = fieldValue(fieldValue(prepare, 2), 3);
    if (skipTo) {
        NSArray *named = entriesIn(skipTo);
        if (named.count) return named.firstObject;
    }
    if ([method isEqualToString:@"SkipToTrack"]) return entries.firstObject;
    return entries.count == 1 ? entries.firstObject : nil;
}

#pragma mark - downloading and indexing

// Downloads (when needed) and waits for Spotify's local files to list the file; completion on gQueue.
static void ready(SCEntry *entry, BOOL announce, void (^completion)(BOOL ok)) {
    BOOL had = [SCLibrary.shared pathForEntry:entry] != nil;
    if (!had && announce) SCToast([NSString stringWithFormat:@"SoundCloud: загружаю «%@»…", entry.title]);
    [SCDownloader.shared ensureEntry:entry completion:^(NSString *path, NSError *error) {
        if (!path) {
            if (announce) SCToast([NSString stringWithFormat:@"SoundCloud: не удалось загрузить (%@)", error.localizedDescription]);
            dispatch_async(gQueue, ^{ completion(NO); });
            return;
        }
        [SCLibrary.shared evictKeeping:[NSSet setWithObject:@(entry.trackID)]];
        if (had && entry.indexedURI) { dispatch_async(gQueue, ^{ completion(YES); }); return; }
        SCLocalFilesFindURI(entry.title, entry.artist, 25, ^(NSString *uri) {
            if (uri) {
                if (![uri isEqualToString:entry.uri]) SCLog(@"playback", @"Spotify indexed %@ as %@", entry.uri, uri);
                [SCLibrary.shared entry:entry indexedAs:uri];
            }
            dispatch_async(gQueue, ^{ completion(YES); });
        });
    }];
}

static NSData *withIndexedURIs(NSData *payload, NSArray<SCEntry *> *entries) {
    NSData *out = payload;
    for (SCEntry *e in entries) {
        if (!e.indexedURI || [e.indexedURI isEqualToString:e.uri]) continue;
        NSData *replaced = SCProtoReplaceString(out, e.uri, e.indexedURI);
        if (replaced) out = replaced;
    }
    return out;
}

static NSMutableSet<NSNumber *> *gPrefetching;

static void prefetch(NSArray<SCEntry *> *entries, NSUInteger count) {
    if (!SCFeatureEnabled(SCFeaturePrefetch)) return;
    NSUInteger started = 0;
    for (SCEntry *e in entries) {
        if (started >= count) break;
        if ([SCLibrary.shared pathForEntry:e] && e.indexedURI) continue;
        started++;
        dispatch_async(gQueue, ^{
            if ([gPrefetching containsObject:@(e.trackID)]) return;
            [gPrefetching addObject:@(e.trackID)];
            SCLog(@"prefetch", @"%lld \"%@\"", e.trackID, e.title);
            ready(e, NO, ^(BOOL ok) { [gPrefetching removeObject:@(e.trackID)]; });
        });
    }
}

#pragma mark - the transport hooks

typedef id (*CallBlock)(id, SEL, id, id, id, id);
static CallBlock gCosmosSingle, gCosmosStream, gBridgeSingle, gBridgeStream;

static BOOL holdsFor(NSString *method) {
    return [method isEqualToString:@"Play"] || [method isEqualToString:@"PreparePlay"] || [method isEqualToString:@"SkipToTrack"];
}

static id newLifetime(void (^cancel)(void)) {
    Class factory = objc_getClass("SPTEsperantoFactory");
    SEL make = @selector(createSPTEsperantoLifetimeWithCancelBlock:);
    if (![factory respondsToSelector:make]) return nil;
    return ((id (*)(id, SEL, id))objc_msgSend)(factory, make, cancel);
}

static id single(CallBlock orig, id self, SEL _cmd, id service, id method, id payload, id onResponse) {
    if (orig == gCosmosSingle) SCEsperantoSetCosmosTransport(self);
    if (!SCFeatureEnabled(SCFeaturePlayback) || ![method isKindOfClass:NSString.class]) return orig(self, _cmd, service, method, payload, onResponse);
    __block NSArray<SCEntry *> *entries = @[];
    SCGuard(SCFeaturePlayback, @"payload", ^{ entries = entriesIn(payload); });
    if (!entries.count) return orig(self, _cmd, service, method, payload, onResponse);

    SCEntry *start = holdsFor(method) ? startTrack(method, payload, entries) : nil;
    BOOL missing = start && !([SCLibrary.shared pathForEntry:start] && start.indexedURI);
    NSData *rewritten = withIndexedURIs(payload, entries);
    if (!missing) {
        if (start) [SCLibrary.shared touch:start];
        prefetch(entries, 3);
        return orig(self, _cmd, service, method, rewritten, onResponse);
    }
    __block BOOL cancelled = NO;
    id lifetime = newLifetime(^{ cancelled = YES; });
    if (!lifetime) {
        // No way to hand Spotify a pending call: let it fail now and have the file ready for the next tap.
        ready(start, YES, ^(BOOL ok) { if (ok) SCToast(@"SoundCloud: готово, нажми ещё раз"); });
        return orig(self, _cmd, service, method, rewritten, onResponse);
    }
    SCLog(@"playback", @"%@ %@ held for %lld \"%@\"", service, method, start.trackID, start.title);
    ready(start, YES, ^(BOOL ok) {
        if (cancelled) return;
        NSData *now = withIndexedURIs(payload, entries);
        dispatch_async(dispatch_get_main_queue(), ^{
            SCLog(@"playback", @"%@ released (%@)", method, ok ? @"ready" : @"download failed");
            orig(self, _cmd, service, method, now, onResponse);
        });
        prefetch(entries, 3);
    });
    return lifetime;
}

// ContextPlayer state updates name the current and next tracks: the next SC ones are prefetched.
static NSString *gLastStateSignature;
static id stream(CallBlock orig, id self, SEL _cmd, id service, id method, id payload, id onResponse) {
    if (orig == gCosmosStream) SCEsperantoSetCosmosTransport(self);
    const char *signature = SCBlockSignature(onResponse);
    BOOL wanted = [method isKindOfClass:NSString.class] && [method isEqualToString:@"GetState"] && signature &&
                  strncmp(signature, "B16@?0@", 7) == 0 && SCFeatureEnabled(SCFeaturePrefetch);
    if (!wanted) return orig(self, _cmd, service, method, payload, onResponse);
    BOOL (^original)(id) = onResponse;
    BOOL (^wrapped)(id) = ^BOOL(id response) {
        SCGuard(SCFeaturePrefetch, @"state", ^{
            NSArray<SCEntry *> *entries = entriesIn(response);
            if (!entries.count) return;
            NSString *signatureNow = [[entries valueForKey:@"uri"] componentsJoinedByString:@"|"];
            if ([signatureNow isEqualToString:gLastStateSignature]) return;
            gLastStateSignature = signatureNow;
            prefetch(entries, 3);
        });
        return original(response);
    };
    return orig(self, _cmd, service, method, payload, wrapped);
}

static id cosmosSingle(id self, SEL _cmd, id s, id m, id p, id r) { return single(gCosmosSingle, self, _cmd, s, m, p, r); }
static id bridgeSingle(id self, SEL _cmd, id s, id m, id p, id r) { return single(gBridgeSingle, self, _cmd, s, m, p, r); }
static id cosmosStream(id self, SEL _cmd, id s, id m, id p, id r) { return stream(gCosmosStream, self, _cmd, s, m, p, r); }
static id bridgeStream(id self, SEL _cmd, id s, id m, id p, id r) { return stream(gBridgeStream, self, _cmd, s, m, p, r); }

#pragma mark - local files switch

typedef id (*Obj0)(id, SEL);
static Obj0 gProvideModel;
static BOOL gEnableTried;

static id provideModel(id self, SEL _cmd) {
    id model = gProvideModel(self, _cmd);
    SCGuard(SCFeaturePlayback, @"local files switch", ^{
        if (gEnableTried || ![model respondsToSelector:@selector(enabled)] || ![model respondsToSelector:NSSelectorFromString(@"enable:")]) return;
        gEnableTried = YES;
        BOOL enabled = ((BOOL (*)(id, SEL))objc_msgSend)(model, @selector(enabled));
        if (enabled) return;
        SCLog(@"localfiles", @"turning Spotify's local files on");
        dispatch_async(dispatch_get_main_queue(), ^{
            ((void (*)(id, SEL, id))objc_msgSend)(model, NSSelectorFromString(@"enable:"), ^{
                SCLog(@"localfiles", @"local files switch answered");
            });
        });
    });
    return model;
}

void SCPlaybackHookStart(void) {
    gQueue = dispatch_queue_create("spotcloud.playback", DISPATCH_QUEUE_SERIAL);
    gPrefetching = [NSMutableSet set];
    Class cosmos = objc_getClass("SPTEsperantoCosmosTransport"), bridge = objc_getClass("SPTEsperantoTransportBridgeImpl");
    SEL s = @selector(callSingle:method:payload:onResponse:), st = @selector(callStream:method:payload:onResponse:);
    gCosmosSingle = (CallBlock)SCSwizzle(cosmos, s, (IMP)cosmosSingle);
    gCosmosStream = (CallBlock)SCSwizzle(cosmos, st, (IMP)cosmosStream);
    gBridgeSingle = (CallBlock)SCSwizzle(bridge, s, (IMP)bridgeSingle);
    gBridgeStream = (CallBlock)SCSwizzle(bridge, st, (IMP)bridgeStream);
    gProvideModel = (Obj0)SCSwizzle(objc_getClass("LocalFiles_CoreImpl.LocalFilesAPIService"), @selector(provideLocalFilesSettingsModel), (IMP)provideModel);
    SCLog(@"playback", @"transports: cosmos %d/%d bridge %d/%d, local files switch %d", gCosmosSingle != NULL, gCosmosStream != NULL,
          gBridgeSingle != NULL, gBridgeStream != NULL, gProvideModel != NULL);
    // Once the transport is known: Documents as a local files source.
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 12 * NSEC_PER_SEC), gQueue, ^{
        if (SCEsperantoReady()) SCLocalFilesEnableDocuments();
        else SCLog(@"localfiles", @"no Cosmos transport seen yet");
    });
}
