#import "SCDownloader.h"
#import <AVFoundation/AVFoundation.h>
#import <CoreMedia/CoreMedia.h>
#import "../Core/SCLog.h"
#import "../SoundCloud/SCClient.h"
#import "../SoundCloud/SCFilter.h"

static NSError *dlError(NSString *text) {
    return [NSError errorWithDomain:@"SpotCloud.Download" code:1 userInfo:@{NSLocalizedDescriptionKey: text}];
}

static NSString *safeFileName(NSString *s) {
    NSCharacterSet *bad = [NSCharacterSet characterSetWithCharactersInString:@"/\\:?%*|\"<>\n\r\t"];
    NSString *clean = [[s componentsSeparatedByCharactersInSet:bad] componentsJoinedByString:@" "];
    return clean.length > 120 ? [clean substringToIndex:120] : clean;
}

@implementation SCDownloader {
    dispatch_queue_t _queue;
    NSMutableDictionary<NSNumber *, NSMutableArray *> *_waiting;
}

+ (instancetype)shared {
    static SCDownloader *d;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ d = [self new]; });
    return d;
}

- (instancetype)init {
    if ((self = [super init])) {
        _queue = dispatch_queue_create("spotcloud.download", DISPATCH_QUEUE_SERIAL);
        _waiting = [NSMutableDictionary dictionary];
    }
    return self;
}

- (BOOL)isDownloading:(long long)trackID {
    __block BOOL busy;
    dispatch_sync(_queue, ^{ busy = self->_waiting[@(trackID)] != nil; });
    return busy;
}

- (void)ensureEntry:(SCEntry *)entry completion:(void (^)(NSString *, NSError *))completion {
    NSString *existing = [SCLibrary.shared pathForEntry:entry];
    if (existing) {
        [SCLibrary.shared touch:entry];
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{ completion(existing, nil); });
        return;
    }
    dispatch_async(_queue, ^{
        NSNumber *key = @(entry.trackID);
        NSMutableArray *waiters = self->_waiting[key];
        if (waiters) {
            [waiters addObject:completion];
            return;
        }
        self->_waiting[key] = [NSMutableArray arrayWithObject:completion];
        SCLog(@"download", @"start %lld \"%@\"", entry.trackID, entry.title);
        [self download:entry finish:^(NSString *path, NSError *error) {
            dispatch_async(self->_queue, ^{
                NSArray *all = self->_waiting[key];
                [self->_waiting removeObjectForKey:key];
                if (path) SCLog(@"download", @"done %lld -> %@", entry.trackID, path.lastPathComponent);
                else SCLog(@"download", @"failed %lld: %@", entry.trackID, error.localizedDescription);
                for (void (^waiter)(NSString *, NSError *) in all) {
                    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{ waiter(path, error); });
                }
            });
        }];
    });
}

- (void)download:(SCEntry *)entry finish:(void (^)(NSString *, NSError *))finish {
    SCClient *client = SCClient.shared;
    [client trackWithID:entry.trackID completion:^(SCTrack *track, NSError *error) {
        if (!track) { finish(nil, error ?: dlError(@"track not found")); return; }
        if (!SCTrackIsPlayable(track)) { finish(nil, dlError(@"Go+, encrypted or a preview")); return; }
        SCTranscoding *transcoding = SCBestTranscoding(track);
        [client streamURLForTranscoding:transcoding track:track completion:^(NSURL *url, NSError *streamError) {
            if (!url) { finish(nil, streamError ?: dlError(@"no stream")); return; }
            BOOL hls = [transcoding.protocol isEqualToString:@"hls"];
            void (^joined)(NSData *, NSError *) = ^(NSData *media, NSError *joinError) {
                if (!media.length) { finish(nil, joinError ?: dlError(@"empty stream")); return; }
                [self fetchArtwork:entry then:^(NSData *artwork) {
                    [self save:media aac:transcoding.isAAC entry:entry artwork:artwork finish:finish];
                }];
            };
            if (hls) [self joinPlaylist:url completion:joined];
            else [client fetch:url completion:joined];
        }];
    }];
}

#pragma mark - HLS

static NSURL *resolve(NSString *line, NSURL *base) {
    return [NSURL URLWithString:line relativeToURL:base].absoluteURL;
}

// The playlist's init map (fMP4) and its segments, fetched four at a time and joined in order.
- (void)joinPlaylist:(NSURL *)playlistURL completion:(void (^)(NSData *, NSError *))completion {
    [SCClient.shared fetch:playlistURL completion:^(NSData *data, NSError *error) {
        NSString *text = data ? [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] : nil;
        if (!text) { completion(nil, error ?: dlError(@"no playlist")); return; }
        NSMutableArray<NSURL *> *parts = [NSMutableArray array];
        for (NSString *raw in [text componentsSeparatedByCharactersInSet:NSCharacterSet.newlineCharacterSet]) {
            NSString *line = [raw stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
            if ([line hasPrefix:@"#EXT-X-KEY"] && ![line containsString:@"METHOD=NONE"]) { completion(nil, dlError(@"encrypted stream")); return; }
            if ([line hasPrefix:@"#EXT-X-MAP:"]) {
                NSRange uri = [line rangeOfString:@"URI=\""];
                if (uri.location != NSNotFound) {
                    NSString *rest = [line substringFromIndex:NSMaxRange(uri)];
                    NSRange end = [rest rangeOfString:@"\""];
                    if (end.location != NSNotFound) [parts insertObject:resolve([rest substringToIndex:end.location], playlistURL) atIndex:0];
                }
                continue;
            }
            if (line.length && ![line hasPrefix:@"#"]) [parts addObject:resolve(line, playlistURL)];
        }
        if (!parts.count) { completion(nil, dlError(@"empty playlist")); return; }
        NSMutableArray *chunks = [NSMutableArray arrayWithCapacity:parts.count];
        for (NSUInteger i = 0; i < parts.count; i++) [chunks addObject:[NSNull null]];
        dispatch_group_t group = dispatch_group_create();
        dispatch_semaphore_t slots = dispatch_semaphore_create(4);
        __block NSError *failure = nil;
        NSLock *lock = [NSLock new];
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
            for (NSUInteger i = 0; i < parts.count; i++) {
                dispatch_semaphore_wait(slots, DISPATCH_TIME_FOREVER);
                dispatch_group_enter(group);
                [SCClient.shared fetch:parts[i] completion:^(NSData *chunk, NSError *chunkError) {
                    [lock lock];
                    if (chunk) chunks[i] = chunk;
                    else failure = chunkError ?: dlError(@"segment failed");
                    [lock unlock];
                    dispatch_semaphore_signal(slots);
                    dispatch_group_leave(group);
                }];
            }
            dispatch_group_notify(group, dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
                if (failure) { completion(nil, failure); return; }
                NSMutableData *joined = [NSMutableData data];
                for (NSData *chunk in chunks) [joined appendData:chunk];
                completion(joined, nil);
            });
        });
    }];
}

- (void)fetchArtwork:(SCEntry *)entry then:(void (^)(NSData *))then {
    NSURL *url = entry.artworkURL ? [NSURL URLWithString:entry.artworkURL] : nil;
    if (!url) { then(nil); return; }
    [SCClient.shared fetch:url completion:^(NSData *data, NSError *error) { then(data); }];
}

#pragma mark - files

- (void)save:(NSData *)media aac:(BOOL)aac entry:(SCEntry *)entry artwork:(NSData *)artwork finish:(void (^)(NSString *, NSError *))finish {
    NSString *base = safeFileName([NSString stringWithFormat:@"%@ - %@ [%lld]", entry.artist, entry.title, entry.trackID]);
    NSString *tmp = [NSTemporaryDirectory() stringByAppendingPathComponent:[NSUUID UUID].UUIDString];
    [NSFileManager.defaultManager createDirectoryAtPath:tmp withIntermediateDirectories:YES attributes:nil error:nil];
    NSString *dir = SCLibrary.shared.tracksDirectory;
    if (!aac) {
        NSString *name = [base stringByAppendingPathExtension:@"mp3"];
        NSMutableData *file = [self id3TagFor:entry artwork:artwork];
        [file appendData:media];
        NSString *path = [dir stringByAppendingPathComponent:name];
        if (![file writeToFile:path atomically:YES]) { finish(nil, dlError(@"could not write the file")); return; }
        [SCLibrary.shared entry:entry savedAs:name size:file.length];
        [NSFileManager.defaultManager removeItemAtPath:tmp error:nil];
        finish(path, nil);
        return;
    }
    NSString *source = [tmp stringByAppendingPathComponent:@"joined.mp4"];
    NSString *output = [tmp stringByAppendingPathComponent:@"out.m4a"];
    [media writeToFile:source atomically:NO];
    AVURLAsset *asset = [AVURLAsset URLAssetWithURL:[NSURL fileURLWithPath:source] options:nil];
    AVAssetExportSession *export = [AVAssetExportSession exportSessionWithAsset:asset presetName:AVAssetExportPresetPassthrough];
    if (!export) { finish(nil, dlError(@"no export session")); return; }
    export.outputURL = [NSURL fileURLWithPath:output];
    export.outputFileType = AVFileTypeAppleM4A;
    export.metadata = [self metadataFor:entry artwork:artwork];
    [export exportAsynchronouslyWithCompletionHandler:^{
        if (export.status != AVAssetExportSessionStatusCompleted) {
            [NSFileManager.defaultManager removeItemAtPath:tmp error:nil];
            finish(nil, export.error ?: dlError(@"remux failed"));
            return;
        }
        NSString *name = [base stringByAppendingPathExtension:@"m4a"];
        NSString *path = [dir stringByAppendingPathComponent:name];
        [NSFileManager.defaultManager removeItemAtPath:path error:nil];
        NSError *moveError = nil;
        if (![NSFileManager.defaultManager moveItemAtPath:output toPath:path error:&moveError]) {
            finish(nil, moveError);
            return;
        }
        unsigned long long size = [[NSFileManager.defaultManager attributesOfItemAtPath:path error:nil] fileSize];
        [SCLibrary.shared entry:entry savedAs:name size:size];
        [NSFileManager.defaultManager removeItemAtPath:tmp error:nil];
        finish(path, nil);
    }];
}

static AVMutableMetadataItem *item(AVMetadataIdentifier identifier, id value) {
    AVMutableMetadataItem *i = [AVMutableMetadataItem metadataItem];
    i.identifier = identifier;
    i.value = value;
    return i;
}

- (NSArray<AVMetadataItem *> *)metadataFor:(SCEntry *)entry artwork:(NSData *)artwork {
    NSString *comment = [NSString stringWithFormat:@"SC:%lld", entry.trackID];
    NSMutableArray *items = [NSMutableArray arrayWithArray:@[
        item(AVMetadataIdentifieriTunesMetadataSongName, entry.title),
        item(AVMetadataIdentifieriTunesMetadataArtist, entry.artist),
        item(AVMetadataIdentifieriTunesMetadataAlbum, SCAlbumName),
        item(AVMetadataIdentifieriTunesMetadataUserComment, comment),
    ]];
    if (artwork.length) {
        AVMutableMetadataItem *cover = item(AVMetadataIdentifieriTunesMetadataCoverArt, artwork);
        cover.dataType = (__bridge NSString *)kCMMetadataBaseDataType_JPEG;
        [items addObject:cover];
    }
    return items;
}

// ID3v2.3: TIT2, TPE1, TALB, COMM ("SC:<id>"), APIC.
static void frame(NSMutableData *tag, const char *frameID, NSData *body) {
    uint32_t size = CFSwapInt32HostToBig((uint32_t)body.length);
    [tag appendBytes:frameID length:4];
    [tag appendBytes:&size length:4];
    uint16_t flags = 0;
    [tag appendBytes:&flags length:2];
    [tag appendData:body];
}

static NSData *textBody(NSString *text) {
    NSMutableData *body = [NSMutableData dataWithBytes:"\x01" length:1];  // UTF-16 with BOM
    [body appendData:[text dataUsingEncoding:NSUnicodeStringEncoding]];
    return body;
}

- (NSMutableData *)id3TagFor:(SCEntry *)entry artwork:(NSData *)artwork {
    NSMutableData *frames = [NSMutableData data];
    frame(frames, "TIT2", textBody(entry.title));
    frame(frames, "TPE1", textBody(entry.artist));
    frame(frames, "TALB", textBody(SCAlbumName));
    NSMutableData *comment = [NSMutableData dataWithBytes:"\x00" "eng" "\x00" length:5];
    [comment appendData:[[NSString stringWithFormat:@"SC:%lld", entry.trackID] dataUsingEncoding:NSISOLatin1StringEncoding]];
    frame(frames, "COMM", comment);
    if (artwork.length) {
        NSMutableData *picture = [NSMutableData dataWithBytes:"\x00" "image/jpeg\x00" "\x03" "\x00" length:14];
        [picture appendData:artwork];
        frame(frames, "APIC", picture);
    }
    NSMutableData *tag = [NSMutableData dataWithBytes:"ID3\x03\x00\x00" length:6];
    uint32_t n = (uint32_t)frames.length;
    uint8_t size[4] = {(n >> 21) & 0x7f, (n >> 14) & 0x7f, (n >> 7) & 0x7f, n & 0x7f};
    [tag appendBytes:size length:4];
    [tag appendData:frames];
    return tag;
}

@end
