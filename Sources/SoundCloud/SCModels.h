#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

// One entry of a track's media.transcodings.
@interface SCTranscoding : NSObject
@property (nonatomic, copy) NSString *url;          // api-v2 URL that answers {"url": <stream>}
@property (nonatomic, copy) NSString *protocol;     // "hls", "progressive", "ctr-encrypted-hls", ...
@property (nonatomic, copy) NSString *mimeType;     // "audio/mp4; codecs=\"mp4a.40.2\"", "audio/mpeg", ...
@property (nonatomic, copy) NSString *preset;       // "aac_160k", "mp3_0_0", ...
@property (nonatomic, copy) NSString *quality;      // "sq", "hq"
@property (nonatomic) BOOL snipped;                 // a 30 s preview
@property (nonatomic, readonly) BOOL encrypted;
@property (nonatomic, readonly) BOOL isAAC;
@property (nonatomic, readonly) BOOL isMP3;
+ (nullable instancetype)transcodingWithJSON:(NSDictionary *)json;
@end

@interface SCTrack : NSObject
@property (nonatomic) long long trackID;
@property (nonatomic, copy) NSString *title;
@property (nonatomic, copy) NSString *username;     // the uploader's nick
@property (nonatomic, copy, nullable) NSString *publisherArtist; // publisher_metadata.artist
@property (nonatomic, copy, nullable) NSString *permalinkURL;
@property (nonatomic, copy, nullable) NSString *artworkURL;      // already the 500x500 variant
@property (nonatomic, copy, nullable) NSString *trackAuthorization;
@property (nonatomic, copy, nullable) NSString *policy;          // ALLOW, MONETIZE, SNIP, BLOCK
@property (nonatomic, copy, nullable) NSString *monetizationModel;
@property (nonatomic) NSTimeInterval duration;      // seconds, as played
@property (nonatomic) NSTimeInterval fullDuration;  // seconds, of the whole upload
@property (nonatomic) long long playbackCount;
@property (nonatomic) BOOL streamable;
@property (nonatomic, copy) NSArray<SCTranscoding *> *transcodings;
// The artist shown: publisher metadata, else "Artist - Title"'s artist, else the uploader.
@property (nonatomic, readonly) NSString *displayArtist;
// The title shown without the "Artist - " prefix the artist was taken from.
@property (nonatomic, readonly) NSString *displayTitle;
// What Spotify shows everywhere: "<title> (SC)".
@property (nonatomic, readonly) NSString *markedTitle;
+ (nullable instancetype)trackWithJSON:(NSDictionary *)json;
@end

extern NSString *const SCTitleMark; // " (SC)"

NS_ASSUME_NONNULL_END
