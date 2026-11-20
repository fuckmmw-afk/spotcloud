#import <Foundation/Foundation.h>
#import "../SoundCloud/SCModels.h"

NS_ASSUME_NONNULL_BEGIN

extern NSString *const SCAlbumName;        // "SoundCloud"
extern NSString *const SCCacheLimitKey;    // NSUserDefaults "spotcloud.cache.limitMB", default 1024

// spotify:local:<artist>:<album>:<title>:<seconds>, each part form-encoded the way Spotify does.
NSString *SCLocalURI(NSString *artist, NSString *album, NSString *title, NSInteger seconds);

// A SoundCloud track SpotCloud has shown (in search) or saved: what is needed to fetch it again and to
// recognise it by its spotify:local: URI. Persisted in Library/Application Support/SpotCloud/catalog.json.
@interface SCEntry : NSObject
@property (nonatomic) long long trackID;
@property (nonatomic, copy) NSString *title;      // with " (SC)", as tagged and shown
@property (nonatomic, copy) NSString *artist;
@property (nonatomic) NSInteger seconds;
@property (nonatomic, copy, nullable) NSString *artworkURL;
@property (nonatomic, copy) NSString *uri;        // the URI SpotCloud put in the search results
@property (nonatomic, copy, nullable) NSString *indexedURI; // the URI Spotify's local files gave the file
@property (nonatomic, copy, nullable) NSString *file;       // file name in Documents/SoundCloud
@property (nonatomic) unsigned long long size;
@property (nonatomic) NSTimeInterval lastUsed;
@end

// Thread-safe.
@interface SCLibrary : NSObject
+ (instancetype)shared;
@property (nonatomic, readonly) NSString *tracksDirectory;  // Documents/SoundCloud
- (SCEntry *)registerTrack:(SCTrack *)track;
- (nullable SCEntry *)entryForURI:(NSString *)uri;
- (nullable SCEntry *)entryForID:(long long)trackID;
// The saved file when it is still on disk.
- (nullable NSString *)pathForEntry:(SCEntry *)entry;
- (void)entry:(SCEntry *)entry savedAs:(NSString *)fileName size:(unsigned long long)size;
- (void)entry:(SCEntry *)entry indexedAs:(NSString *)uri;
- (void)touch:(SCEntry *)entry;
// Deletes the least recently used files until the total fits the limit; never `keep`.
- (void)evictKeeping:(nullable NSSet<NSNumber *> *)keep;
- (unsigned long long)cachedBytes;
- (void)removeAllFiles;
@end

NS_ASSUME_NONNULL_END
