#import "SCClient.h"
#import "SCFilter.h"
#import "../Core/SCLog.h"

NSString *const SCClientIDKey = @"spotcloud.sc.clientID";
NSString *const SCOAuthTokenKey = @"spotcloud.sc.oauthToken";
static NSString *const kAPI = @"https://api-v2.soundcloud.com";
static NSString *const kUserAgent = @"Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Mobile/15E148 Safari/604.1";

typedef void (^SCDataCompletion)(NSData *_Nullable data, NSHTTPURLResponse *_Nullable response, NSError *_Nullable error);

static NSError *scError(NSInteger code, NSString *text) {
    return [NSError errorWithDomain:@"SpotCloud.SoundCloud" code:code userInfo:@{NSLocalizedDescriptionKey: text}];
}

@implementation SCClient {
    NSURLSession *_session;
    dispatch_queue_t _queue;
    NSMutableDictionary<NSString *, NSMutableArray<SCDataCompletion> *> *_inFlight;
    NSMutableArray<void (^)(NSString *, NSError *)> *_clientIDWaiters;
}

+ (instancetype)shared {
    static SCClient *client;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ client = [self new]; });
    return client;
}

- (instancetype)init {
    if ((self = [super init])) {
        _queue = dispatch_queue_create("spotcloud.sc.client", DISPATCH_QUEUE_SERIAL);
        NSURLSessionConfiguration *config = NSURLSessionConfiguration.ephemeralSessionConfiguration;
        config.timeoutIntervalForRequest = 20;
        config.HTTPMaximumConnectionsPerHost = 6;
        config.HTTPAdditionalHeaders = @{@"User-Agent": kUserAgent, @"Accept": @"application/json, */*"};
        NSOperationQueue *delegateQueue = [NSOperationQueue new];
        delegateQueue.underlyingQueue = _queue;
        delegateQueue.maxConcurrentOperationCount = 1;
        _session = [NSURLSession sessionWithConfiguration:config delegate:nil delegateQueue:delegateQueue];
        _inFlight = [NSMutableDictionary dictionary];
    }
    return self;
}

- (NSString *)clientID { return [NSUserDefaults.standardUserDefaults stringForKey:SCClientIDKey]; }
- (NSString *)oauthToken {
    NSString *token = [NSUserDefaults.standardUserDefaults stringForKey:SCOAuthTokenKey];
    return token.length ? token : nil;
}

#pragma mark - transport

// GET with backoff; identical URLs in flight share one request. Runs on _queue.
- (void)get:(NSURL *)url headers:(NSDictionary *)headers attempt:(int)attempt completion:(SCDataCompletion)completion {
    NSString *key = url.absoluteString;
    if (attempt == 0) {
        NSMutableArray *waiting = _inFlight[key];
        if (waiting) {
            [waiting addObject:completion];
            return;
        }
        _inFlight[key] = [NSMutableArray arrayWithObject:completion];
    }
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:url];
    [headers enumerateKeysAndObjectsUsingBlock:^(NSString *k, NSString *v, BOOL *stop) { [request setValue:v forHTTPHeaderField:k]; }];
    [[_session dataTaskWithRequest:request completionHandler:^(NSData *data, NSURLResponse *raw, NSError *error) {
        NSHTTPURLResponse *response = [raw isKindOfClass:NSHTTPURLResponse.class] ? (NSHTTPURLResponse *)raw : nil;
        NSInteger status = response.statusCode;
        BOOL retry = attempt < 3 && (status == 429 || status >= 500 || (error && error.code != NSURLErrorCancelled));
        if (retry) {
            double delay = 0.5 * (1 << attempt);
            NSString *after = response.allHeaderFields[@"Retry-After"];
            if (after.doubleValue > 0) delay = MIN(after.doubleValue, 30);
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay * NSEC_PER_SEC)), self->_queue, ^{
                [self get:url headers:headers attempt:attempt + 1 completion:completion];
            });
            return;
        }
        NSArray *waiters = self->_inFlight[key] ?: @[completion];
        [self->_inFlight removeObjectForKey:key];
        NSError *failure = error;
        if (!failure && (status < 200 || status >= 300)) failure = scError(status, [NSString stringWithFormat:@"HTTP %ld", (long)status]);
        for (SCDataCompletion waiter in waiters) waiter(failure ? nil : data, response, failure);
    }] resume];
}

// An api-v2 call: adds client_id (and OAuth); a 401/403 refreshes client_id once and tries again.
- (void)api:(NSString *)path query:(NSDictionary<NSString *, NSString *> *)query retried:(BOOL)retried
 completion:(void (^)(id _Nullable json, NSError *_Nullable error))completion {
    dispatch_async(_queue, ^{
        NSString *clientID = [self clientID];
        if (!clientID.length) {
            if (retried) { completion(nil, scError(-1, @"no SoundCloud client_id")); return; }
            [self refreshClientID:^(NSString *fresh, NSError *error) {
                if (!fresh) { completion(nil, error); return; }
                [self api:path query:query retried:YES completion:completion];
            }];
            return;
        }
        NSURLComponents *components = [NSURLComponents componentsWithString:[path hasPrefix:@"http"] ? path : [kAPI stringByAppendingString:path]];
        NSMutableArray *items = [NSMutableArray arrayWithArray:components.queryItems ?: @[]];
        [query enumerateKeysAndObjectsUsingBlock:^(NSString *k, NSString *v, BOOL *stop) { [items addObject:[NSURLQueryItem queryItemWithName:k value:v]]; }];
        [items addObject:[NSURLQueryItem queryItemWithName:@"client_id" value:clientID]];
        components.queryItems = items;
        NSMutableDictionary *headers = [NSMutableDictionary dictionary];
        if ([self oauthToken]) headers[@"Authorization"] = [@"OAuth " stringByAppendingString:[self oauthToken]];
        [self get:components.URL headers:headers attempt:0 completion:^(NSData *data, NSHTTPURLResponse *response, NSError *error) {
            if ((response.statusCode == 401 || response.statusCode == 403) && !retried) {
                SCLog(@"sc", @"%ld from %@; fetching a new client_id", (long)response.statusCode, path);
                [self refreshClientID:^(NSString *fresh, NSError *refreshError) {
                    if (!fresh) { completion(nil, error); return; }
                    [self api:path query:query retried:YES completion:completion];
                }];
                return;
            }
            if (error) { completion(nil, error); return; }
            NSError *parseError = nil;
            id json = [NSJSONSerialization JSONObjectWithData:data options:0 error:&parseError];
            completion(json, json ? nil : parseError);
        }];
    });
}

#pragma mark - client_id

static NSString *firstMatch(NSString *text, NSString *pattern) {
    NSRegularExpression *re = [NSRegularExpression regularExpressionWithPattern:pattern options:0 error:nil];
    NSTextCheckingResult *match = [re firstMatchInString:text options:0 range:NSMakeRange(0, text.length)];
    return match && match.numberOfRanges > 1 ? [text substringWithRange:[match rangeAtIndex:1]] : nil;
}

- (void)finishClientID:(NSString *)clientID error:(NSError *)error {
    if (clientID) {
        [NSUserDefaults.standardUserDefaults setObject:clientID forKey:SCClientIDKey];
        SCLog(@"sc", @"client_id refreshed");
    } else {
        SCLog(@"sc", @"could not find a client_id: %@", error.localizedDescription);
    }
    NSArray *waiters = _clientIDWaiters;
    _clientIDWaiters = nil;
    for (void (^waiter)(NSString *, NSError *) in waiters) waiter(clientID, clientID ? nil : error);
}

// soundcloud.com's scripts (newest last) carry client_id:"..."; m.soundcloud.com's page carries "clientId".
- (void)scanScripts:(NSArray<NSString *> *)scripts {
    if (!scripts.count) {
        [self get:[NSURL URLWithString:@"https://m.soundcloud.com/"] headers:@{} attempt:0 completion:^(NSData *data, NSHTTPURLResponse *r, NSError *error) {
            NSString *page = data ? [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] : nil;
            NSString *found = page ? firstMatch(page, @"\"clientId\":\"([A-Za-z0-9]{20,40})\"") : nil;
            [self finishClientID:found error:error ?: scError(-2, @"no client_id on soundcloud.com")];
        }];
        return;
    }
    NSURL *url = [NSURL URLWithString:scripts.lastObject];
    NSArray *rest = [scripts subarrayWithRange:NSMakeRange(0, scripts.count - 1)];
    [self get:url headers:@{} attempt:0 completion:^(NSData *data, NSHTTPURLResponse *r, NSError *error) {
        NSString *script = data ? [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] : nil;
        NSString *found = script ? (firstMatch(script, @"[{,]client_id:\"([A-Za-z0-9]{20,40})\"") ?: firstMatch(script, @"client_id=([A-Za-z0-9]{20,40})")) : nil;
        if (found) [self finishClientID:found error:nil];
        else [self scanScripts:rest];
    }];
}

- (void)refreshClientID:(void (^)(NSString *, NSError *))completion {
    dispatch_async(_queue, ^{
        if (self->_clientIDWaiters) {
            [self->_clientIDWaiters addObject:completion];
            return;
        }
        self->_clientIDWaiters = [NSMutableArray arrayWithObject:completion];
        [self get:[NSURL URLWithString:@"https://soundcloud.com/"] headers:@{} attempt:0 completion:^(NSData *data, NSHTTPURLResponse *r, NSError *error) {
            NSString *page = data ? [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] : @"";
            NSRegularExpression *re = [NSRegularExpression regularExpressionWithPattern:@"<script[^>]+src=\"(https://a-v2\\.sndcdn\\.com/assets/[^\"]+\\.js)\"" options:0 error:nil];
            NSMutableArray *scripts = [NSMutableArray array];
            for (NSTextCheckingResult *m in [re matchesInString:page options:0 range:NSMakeRange(0, page.length)]) {
                [scripts addObject:[page substringWithRange:[m rangeAtIndex:1]]];
            }
            [self scanScripts:scripts];
        }];
    });
}

#pragma mark - API

- (void)searchTracks:(NSString *)query limit:(NSUInteger)limit completion:(void (^)(NSArray<SCTrack *> *, NSError *))completion {
    NSDictionary *params = @{@"q": query, @"limit": [NSString stringWithFormat:@"%lu", (unsigned long)limit], @"offset": @"0",
                             @"linked_partitioning": @"1", @"app_locale": @"en"};
    [self api:@"/search/tracks" query:params retried:NO completion:^(id json, NSError *error) {
        NSArray *collection = [json isKindOfClass:NSDictionary.class] ? json[@"collection"] : nil;
        if (![collection isKindOfClass:NSArray.class]) { completion(nil, error ?: scError(-3, @"no search results")); return; }
        NSMutableArray *tracks = [NSMutableArray array];
        for (id entry in collection) {
            SCTrack *track = [SCTrack trackWithJSON:entry];
            if (track) [tracks addObject:track];
        }
        completion(tracks, nil);
    }];
}

- (void)trackWithID:(long long)trackID completion:(void (^)(SCTrack *, NSError *))completion {
    [self api:[NSString stringWithFormat:@"/tracks/%lld", trackID] query:@{} retried:NO completion:^(id json, NSError *error) {
        SCTrack *track = [SCTrack trackWithJSON:json];
        completion(track, track ? nil : (error ?: scError(-4, @"no such track")));
    }];
}

- (void)resolveURL:(NSString *)url completion:(void (^)(SCTrack *, NSError *))completion {
    [self api:@"/resolve" query:@{@"url": url} retried:NO completion:^(id json, NSError *error) {
        SCTrack *track = [SCTrack trackWithJSON:json];
        completion(track, track ? nil : (error ?: scError(-4, @"not a track")));
    }];
}

- (void)streamURLForTranscoding:(SCTranscoding *)transcoding track:(SCTrack *)track completion:(void (^)(NSURL *, NSError *))completion {
    NSDictionary *query = track.trackAuthorization ? @{@"track_authorization": track.trackAuthorization} : @{};
    [self api:transcoding.url query:query retried:NO completion:^(id json, NSError *error) {
        NSString *url = [json isKindOfClass:NSDictionary.class] ? json[@"url"] : nil;
        completion([url isKindOfClass:NSString.class] ? [NSURL URLWithString:url] : nil, url ? nil : (error ?: scError(-5, @"no stream URL")));
    }];
}

- (void)fetch:(NSURL *)url completion:(void (^)(NSData *, NSError *))completion {
    dispatch_async(_queue, ^{
        [self get:url headers:@{} attempt:0 completion:^(NSData *data, NSHTTPURLResponse *r, NSError *error) { completion(data, error); }];
    });
}

@end
