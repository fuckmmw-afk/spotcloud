#import "SCModels.h"

NS_ASSUME_NONNULL_BEGIN

// Go+ only, encrypted and preview-only tracks are hidden; the rest have a stream SpotCloud can save.
BOOL SCTrackIsPlayable(SCTrack *track);
// The stream to download: AAC over HLS first (remuxed to .m4a), then MP3 over HLS, then progressive MP3.
// Never a snipped or encrypted one. nil when there is none.
SCTranscoding *_Nullable SCBestTranscoding(SCTrack *track);

NS_ASSUME_NONNULL_END
