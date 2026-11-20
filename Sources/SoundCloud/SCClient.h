#import "SCModels.h"

NS_ASSUME_NONNULL_BEGIN

extern NSString *const SCClientIDKey;      // NSUserDefaults "spotcloud.sc.clientID"
extern NSString *const SCOAuthTokenKey;    // NSUserDefaults "spotcloud.sc.oauthToken"

// SoundCloud's api-v2, asynchronous throughout: completions arrive on a private queue, never the main one.
// Requests carry client_id (from settings, else scraped from soundcloud.com) and the OAuth token when set.
// A 401/403 fetches a fresh client_id once and retries; 429 and 5xx back off (Retry-After respected) up to
// three times; identical GETs in flight share one request.
@interface SCClient : NSObject
+ (instancetype)shared;
- (void)searchTracks:(NSString *)query limit:(NSUInteger)limit completion:(void (^)(NSArray<SCTrack *> *_Nullable tracks, NSError *_Nullable error))completion;
- (void)trackWithID:(long long)trackID completion:(void (^)(SCTrack *_Nullable track, NSError *_Nullable error))completion;
- (void)resolveURL:(NSString *)url completion:(void (^)(SCTrack *_Nullable track, NSError *_Nullable error))completion;
// A fresh stream URL (HLS playlist or MP3) for one of the track's transcodings.
- (void)streamURLForTranscoding:(SCTranscoding *)transcoding track:(SCTrack *)track
                     completion:(void (^)(NSURL *_Nullable url, NSError *_Nullable error))completion;
// Plain GET of any URL through the same retrying session (playlists, segments, artwork).
- (void)fetch:(NSURL *)url completion:(void (^)(NSData *_Nullable data, NSError *_Nullable error))completion;
// GET with a Range header (bytes=offset-(offset+length-1)); `total` is the whole resource's size from
// Content-Range (or the body's length when the server ignored the range and sent it all, `whole` = YES).
- (void)fetch:(NSURL *)url offset:(unsigned long long)offset length:(unsigned long long)length
   completion:(void (^)(NSData *_Nullable data, unsigned long long total, BOOL whole, NSError *_Nullable error))completion;
// Scrapes soundcloud.com for a client_id, stores it, answers it.
- (void)refreshClientID:(void (^)(NSString *_Nullable clientID, NSError *_Nullable error))completion;
@end

NS_ASSUME_NONNULL_END
