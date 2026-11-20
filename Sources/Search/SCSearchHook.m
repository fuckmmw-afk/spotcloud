// Mixes SoundCloud tracks into Spotify's search results.
//
// Spotify 9.1.90 fetches search from spclient /searchview/v3/search through Connectivity_HttpClientKit.
// HttpClientURLSession (an NSURLSession delegate). When the response starts, SpotCloud searches SoundCloud
// for the same query; the response body is held back, SoundCloud's playable, de-duplicated tracks are
// added as track entities (MainViewResponse field 1, built on one of Spotify's own track entities), and the
// body is handed on. Each SC track's URI is the spotify:local: URI its saved file will have, so a tap, the
// queue and "next" treat it like any local file (SCPlaybackHook does the download).
#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import "../Core/SCFeatures.h"
#import "../Core/SCLog.h"
#import "../Core/SCProto.h"
#import "../Core/SCSwizzle.h"
#import "../Library/SCLibrary.h"
#import "../SoundCloud/SCClient.h"
#import "../SoundCloud/SCDedup.h"
#import "../SoundCloud/SCFilter.h"

NSString *const SCSearchCountKey = @"spotcloud.search.count";

#pragma mark - SoundCloud results, cached per query

@interface SCSearchJob : NSObject
@property (nonatomic, copy) NSString *query;
@property (nonatomic, copy) NSString *pageToken;
@property (nonatomic, strong) NSMutableData *body;
@property (nonatomic, strong) NSDate *started;
@end
@implementation SCSearchJob
@end

static dispatch_queue_t gQueue;
static NSMutableDictionary<NSString *, NSArray<SCTrack *> *> *gResults;      // query -> tracks
static NSMutableDictionary<NSString *, NSDate *> *gResultTimes;
static NSMutableDictionary<NSString *, NSMutableArray *> *gPending;           // query -> waiters
static NSMutableDictionary<NSString *, NSNumber *> *gFilteredInjected;        // query -> a filtered page got SC

static NSUInteger resultCount(void) {
    NSInteger n = [NSUserDefaults.standardUserDefaults integerForKey:SCSearchCountKey];
    return n > 0 ? (NSUInteger)MIN(n, 20) : 6;
}

// Completion on gQueue.
static void soundCloudResults(NSString *query, void (^completion)(NSArray<SCTrack *> *)) {
    dispatch_async(gQueue, ^{
        NSArray *cached = gResults[query];
        if (cached && [gResultTimes[query] timeIntervalSinceNow] > -600) { completion(cached); return; }
        NSMutableArray *waiters = gPending[query];
        if (waiters) { [waiters addObject:completion]; return; }
        gPending[query] = [NSMutableArray arrayWithObject:completion];
        [SCClient.shared searchTracks:query limit:40 completion:^(NSArray<SCTrack *> *tracks, NSError *error) {
            NSMutableArray *playable = [NSMutableArray array];
            for (SCTrack *t in tracks) if (SCTrackIsPlayable(t)) [playable addObject:t];
            NSArray *kept = SCDeduplicate(playable);
            if (kept.count > resultCount()) kept = [kept subarrayWithRange:NSMakeRange(0, resultCount())];
            if (error) SCLog(@"search", @"SoundCloud search \"%@\" failed: %@", query, error.localizedDescription);
            else SCLog(@"search", @"\"%@\": %lu from SoundCloud, %lu playable, %lu after merging duplicates", query,
                       (unsigned long)tracks.count, (unsigned long)playable.count, (unsigned long)kept.count);
            dispatch_async(gQueue, ^{
                if (!error) {
                    gResults[query] = kept;
                    gResultTimes[query] = [NSDate date];
                }
                NSArray *all = gPending[query];
                [gPending removeObjectForKey:query];
                for (void (^waiter)(NSArray *) in all) waiter(kept ?: @[]);
            });
        }];
    });
}

#pragma mark - the response

static BOOL hasTrackFields(SCProtoField *entity) {
    for (SCProtoField *f in SCProtoParse(entity.value) ?: @[]) if (f.number == 5 && f.wireType == 2) return YES;
    return NO;
}

// One search entity for an SC track, shaped like `template` (one of Spotify's own track entities).
static NSData *entityFor(SCTrack *track, SCEntry *entry, SCProtoField *template) {
    NSMutableData *details = [NSMutableData data];
    NSData *templateDetails = nil;
    for (SCProtoField *f in SCProtoParse(template.value) ?: @[]) if (f.number == 5) templateDetails = f.value;
    BOOL wroteAlbum = NO;
    for (SCProtoField *f in SCProtoParse(templateDetails ?: [NSData data]) ?: @[]) {
        switch (f.number) {
            case 1: break;  // explicit
            case 3: case 4: case 18: {
                if (f.number == 3 && !wroteAlbum) {
                    NSMutableData *album = [NSMutableData data];
                    SCProtoAppendStringField(album, 1, @"");
                    SCProtoAppendStringField(album, 2, SCAlbumName);
                    SCProtoAppendBytesField(details, 3, album);
                    NSMutableData *artist = [NSMutableData data];
                    SCProtoAppendStringField(artist, 1, @"");
                    SCProtoAppendStringField(artist, 2, entry.artist);
                    SCProtoAppendBytesField(details, 4, artist);
                    wroteAlbum = YES;
                }
                break;
            }
            default: [details appendData:f.raw];
        }
    }
    if (!wroteAlbum) {
        NSMutableData *album = [NSMutableData data], *artist = [NSMutableData data];
        SCProtoAppendStringField(album, 1, @"");
        SCProtoAppendStringField(album, 2, SCAlbumName);
        SCProtoAppendBytesField(details, 3, album);
        SCProtoAppendStringField(artist, 1, @"");
        SCProtoAppendStringField(artist, 2, entry.artist);
        SCProtoAppendBytesField(details, 4, artist);
    }
    NSMutableData *duration = [NSMutableData data];
    SCProtoAppendVarintField(duration, 1, (uint64_t)MAX(entry.seconds, 1));
    SCProtoAppendBytesField(details, 18, duration);

    NSMutableData *entity = [NSMutableData data];
    SCProtoAppendStringField(entity, 1, entry.indexedURI ?: entry.uri);
    SCProtoAppendStringField(entity, 2, entry.title);
    SCProtoAppendStringField(entity, 3, track.artworkURL ?: @"");
    SCProtoAppendBytesField(entity, 5, details);
    return entity;
}

static NSData *inject(NSData *body, NSArray<SCTrack *> *tracks, SCSearchJob *job) {
    NSArray<SCProtoField *> *fields = SCProtoParse(body);
    if (!fields || !tracks.count) return nil;
    SCProtoField *template = nil;
    NSUInteger entities = 0;
    for (SCProtoField *f in fields) {
        if (f.number != 1 || f.wireType != 2) continue;
        entities++;
        if (!template && hasTrackFields(f)) template = f;
    }
    // Only views that list tracks: the main results, and the first page of the Tracks filter.
    if (!template) return nil;
    if (job.pageToken.length) {
        if ([gFilteredInjected[job.query] boolValue]) return nil;
        gFilteredInjected[job.query] = @YES;
    } else {
        [gFilteredInjected removeObjectForKey:job.query];
    }
    NSMutableArray<NSData *> *added = [NSMutableArray array];
    for (SCTrack *track in tracks) {
        SCEntry *entry = [SCLibrary.shared registerTrack:track];
        [added addObject:entityFor(track, entry, template)];
    }
    NSUInteger insertAfter = MIN((NSUInteger)2, entities), seen = 0;
    BOOL inserted = NO;
    NSMutableData *out = [NSMutableData dataWithCapacity:body.length + 4096];
    for (SCProtoField *f in fields) {
        if (!inserted && f.number == 1 && seen == insertAfter) {
            for (NSData *e in added) SCProtoAppendBytesField(out, 1, e);
            inserted = YES;
        }
        if (f.number == 1) seen++;
        [out appendData:f.raw];
    }
    if (!inserted) {
        // Fewer entities than the insertion point, or none at all: before the first non-entity field.
        NSMutableData *rebuilt = [NSMutableData data];
        for (NSData *e in added) SCProtoAppendBytesField(rebuilt, 1, e);
        [rebuilt appendData:out];
        out = rebuilt;
    }
    return out;
}

#pragma mark - the delegate hooks

typedef void (*DidReceiveResponse)(id, SEL, NSURLSession *, NSURLSessionDataTask *, NSURLResponse *, id);
typedef void (*DidReceiveData)(id, SEL, NSURLSession *, NSURLSessionDataTask *, NSData *);
typedef void (*DidComplete)(id, SEL, NSURLSession *, NSURLSessionTask *, NSError *);
static DidReceiveResponse gOrigResponse;
static DidReceiveData gOrigData;
static DidComplete gOrigComplete;
static const void *kJobKey = &kJobKey;

static SCSearchJob *jobFor(NSURLSessionTask *task) { return objc_getAssociatedObject(task, kJobKey); }

static void searchDidReceiveResponse(id self, SEL _cmd, NSURLSession *session, NSURLSessionDataTask *task, NSURLResponse *response, id handler) {
    SCGuard(SCFeatureSearch, @"response", ^{
        NSURL *url = task.currentRequest.URL;
        NSHTTPURLResponse *http = [response isKindOfClass:NSHTTPURLResponse.class] ? (NSHTTPURLResponse *)response : nil;
        if (![url.path hasSuffix:@"/searchview/v3/search"] || http.statusCode != 200 || !SCFeatureEnabled(SCFeatureSearch)) return;
        NSURLComponents *components = [NSURLComponents componentsWithURL:url resolvingAgainstBaseURL:NO];
        NSString *query = nil, *pageToken = nil;
        for (NSURLQueryItem *q in components.queryItems) {
            if ([q.name isEqualToString:@"query"]) query = q.value;
            if ([q.name isEqualToString:@"page_token"]) pageToken = q.value;
        }
        query = [query stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
        if (query.length < 2) return;
        SCSearchJob *job = [SCSearchJob new];
        job.query = query;
        job.pageToken = pageToken;
        job.body = [NSMutableData data];
        job.started = [NSDate date];
        objc_setAssociatedObject(task, kJobKey, job, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        soundCloudResults(query, ^(NSArray *tracks) {});  // start now; the body is held until it is done
    });
    gOrigResponse(self, _cmd, session, task, response, handler);
}

static void searchDidReceiveData(id self, SEL _cmd, NSURLSession *session, NSURLSessionDataTask *task, NSData *data) {
    SCSearchJob *job = jobFor(task);
    if (job) {
        [job.body appendData:data];
        return;
    }
    gOrigData(self, _cmd, session, task, data);
}

static void searchDidComplete(id self, SEL _cmd, NSURLSession *session, NSURLSessionTask *task, NSError *error) {
    SCSearchJob *job = jobFor(task);
    if (!job) {
        gOrigComplete(self, _cmd, session, task, error);
        return;
    }
    objc_setAssociatedObject(task, kJobKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    NSData *original = [job.body copy];
    NSOperationQueue *delegateQueue = session.delegateQueue;
    void (^deliver)(NSData *) = ^(NSData *body) {
        void (^hand)(void) = ^{
            if (body.length) gOrigData(self, _cmd, session, (NSURLSessionDataTask *)task, body);
            gOrigComplete(self, _cmd, session, task, error);
        };
        if (delegateQueue) [delegateQueue addOperationWithBlock:hand];
        else hand();
    };
    if (error || !original.length) {
        deliver(original);
        return;
    }
    // Wait for SoundCloud at most ~2.5 s after the response began; Spotify's own results never wait longer.
    __block BOOL delivered = NO;
    NSLock *lock = [NSLock new];
    void (^once)(NSData *) = ^(NSData *body) {
        [lock lock];
        BOOL first = !delivered;
        delivered = YES;
        [lock unlock];
        if (first) deliver(body);
    };
    double wait = MAX(0.2, 2.5 + [job.started timeIntervalSinceNow]);
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(wait * NSEC_PER_SEC)), gQueue, ^{
        if (!delivered) SCLog(@"search", @"\"%@\": SoundCloud too slow, Spotify's results shown alone", job.query);
        once(original);
    });
    soundCloudResults(job.query, ^(NSArray<SCTrack *> *tracks) {
        __block NSData *patched = nil;
        SCGuard(SCFeatureSearch, @"inject", ^{ patched = inject(original, tracks, job); });
        if (patched) {
            SCLog(@"search", @"\"%@\"%@: %lu SC tracks added", job.query, job.pageToken.length ? @" (filtered page)" : @"", (unsigned long)tracks.count);
            static int dumped = 0;
            if (dumped < 3 && SCFeatureEnabled(SCFeatureProbe)) {
                NSString *dir = [SCSupportDirectory() stringByAppendingPathComponent:@"dumps"];
                [NSFileManager.defaultManager createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];
                [patched writeToFile:[dir stringByAppendingPathComponent:[NSString stringWithFormat:@"injected-%d.bin", dumped++]] atomically:YES];
            }
        }
        once(patched ?: original);
    });
}

void SCSearchHookStart(void) {
    gQueue = dispatch_queue_create("spotcloud.search", DISPATCH_QUEUE_SERIAL);
    gResults = [NSMutableDictionary dictionary];
    gResultTimes = [NSMutableDictionary dictionary];
    gPending = [NSMutableDictionary dictionary];
    gFilteredInjected = [NSMutableDictionary dictionary];
    Class cls = objc_getClass("Connectivity_HttpClientKit.HttpClientURLSession");
    if (!cls) {
        SCLog(@"search", @"HttpClientURLSession is not in this build; search stays Spotify-only");
        return;
    }
    SEL selectors[] = {@selector(URLSession:dataTask:didReceiveResponse:completionHandler:), @selector(URLSession:dataTask:didReceiveData:),
                       @selector(URLSession:task:didCompleteWithError:)};
    for (int i = 0; i < 3; i++) {
        if (!class_getInstanceMethod(cls, selectors[i])) {
            SCLog(@"search", @"HttpClientURLSession lacks %@; search stays Spotify-only", NSStringFromSelector(selectors[i]));
            return;
        }
    }
    gOrigResponse = (DidReceiveResponse)SCSwizzle(cls, @selector(URLSession:dataTask:didReceiveResponse:completionHandler:), (IMP)searchDidReceiveResponse);
    gOrigData = (DidReceiveData)SCSwizzle(cls, @selector(URLSession:dataTask:didReceiveData:), (IMP)searchDidReceiveData);
    gOrigComplete = (DidComplete)SCSwizzle(cls, @selector(URLSession:task:didCompleteWithError:), (IMP)searchDidComplete);
    if (!gOrigResponse || !gOrigData || !gOrigComplete) {
        SCLog(@"search", @"could not hook HttpClientURLSession (%d %d %d)", gOrigResponse != NULL, gOrigData != NULL, gOrigComplete != NULL);
        return;
    }
    // A client_id ready before the first search.
    if (![NSUserDefaults.standardUserDefaults stringForKey:SCClientIDKey].length) {
        [SCClient.shared refreshClientID:^(NSString *clientID, NSError *error) {}];
    }
    SCLog(@"search", @"search results get SoundCloud tracks");
}
