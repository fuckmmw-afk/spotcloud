#import <Foundation/Foundation.h>
#import "../Library/SCLibrary.h"

NS_ASSUME_NONNULL_BEGIN

// Saves a SoundCloud track into Documents/SoundCloud: a fresh stream URL, the HLS segments joined, remuxed
// to .m4a without re-encoding (AAC) or kept as .mp3 (MP3), tagged with title "<title> (SC)", artist, album
// "SoundCloud", the SC ID in the comment and the artwork. One download per track at a time; callers of a
// track already downloading wait for the same result. Completion on a global queue.
@interface SCDownloader : NSObject
+ (instancetype)shared;
- (void)ensureEntry:(SCEntry *)entry completion:(void (^)(NSString *_Nullable path, NSError *_Nullable error))completion;
- (BOOL)isDownloading:(long long)trackID;
@end

NS_ASSUME_NONNULL_END
