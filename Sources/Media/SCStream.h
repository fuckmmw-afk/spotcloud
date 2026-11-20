#import <Foundation/Foundation.h>
#import "../Library/SCLibrary.h"

NS_ASSUME_NONNULL_BEGIN

// Streams a SoundCloud track into a file Spotify can play while it is still downloading.
//
// From the HLS playlist (fMP4: an init segment and ~10 s fragments) only the start of every fragment is read
// first (HTTP ranges): its moof lists the size of every AAC frame. That is enough to write a complete,
// ordinary .m4a header at once — moov with the full sample table, tags (title "<title> (SC)", album
// "SoundCloud", the SC ID in the comment, cover) — and the file is sized for all the audio. The fragments
// are then fetched in order (from wherever the player seeks to) and their frames written in place; at the
// end the file is a normal m4a, never re-encoded. Spotify's decoder (ExtAudioFile) is held back
// (SCStreamGuard) when it reads ahead of what has arrived.
@interface SCStream : NSObject
+ (instancetype)shared;
// `playable` once the header and the first fragments are on disk (or the finished file exists): the path,
// or nil and an error. Called once per call, on a global queue. Falls back to a whole download for streams
// that are not fMP4 (MP3).
- (void)startEntry:(SCEntry *)entry playable:(void (^)(NSString *_Nullable path, NSError *_Nullable error))playable;
@end

// Hooks Spotify's ExtAudioFile imports so reads of a file still streaming wait for its data.
void SCStreamGuardStart(void);

NS_ASSUME_NONNULL_END
