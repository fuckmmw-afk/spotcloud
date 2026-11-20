#import "SCStream.h"
#import <AudioToolbox/AudioToolbox.h>
#import <fcntl.h>
#import <unistd.h>
#import "../Core/SCLog.h"
#import "../JDSP/SCRebind.h"
#import "../SoundCloud/SCClient.h"
#import "../SoundCloud/SCFilter.h"
#import "SCDownloader.h"

static NSError *streamError(NSString *text) {
    return [NSError errorWithDomain:@"SpotCloud.Stream" code:1 userInfo:@{NSLocalizedDescriptionKey: text}];
}

#pragma mark - MP4 boxes

static uint32_t be32(const uint8_t *p) { return (uint32_t)p[0] << 24 | (uint32_t)p[1] << 16 | (uint32_t)p[2] << 8 | p[3]; }
static uint64_t be64(const uint8_t *p) { return (uint64_t)be32(p) << 32 | be32(p + 4); }
static void put32(NSMutableData *d, uint32_t v) { uint32_t b = CFSwapInt32HostToBig(v); [d appendBytes:&b length:4]; }
static void put16(NSMutableData *d, uint16_t v) { uint16_t b = CFSwapInt16HostToBig(v); [d appendBytes:&b length:2]; }

static NSData *box(const char *type, NSData *payload) {
    NSMutableData *d = [NSMutableData dataWithCapacity:payload.length + 8];
    put32(d, (uint32_t)payload.length + 8);
    [d appendBytes:type length:4];
    [d appendData:payload];
    return d;
}

static NSData *fullbox(const char *type, uint8_t version, uint32_t flags, NSData *payload) {
    NSMutableData *p = [NSMutableData data];
    put32(p, (uint32_t)version << 24 | (flags & 0xffffff));
    [p appendData:payload];
    return box(type, p);
}

// A box found in a buffer: where it starts, its header and total size.
typedef struct { NSUInteger start, header; uint64_t size; char type[5]; } SCBox;

static BOOL boxAt(const uint8_t *b, NSUInteger length, NSUInteger offset, SCBox *out) {
    if (offset + 8 > length) return NO;
    uint64_t size = be32(b + offset);
    NSUInteger header = 8;
    if (size == 1) {
        if (offset + 16 > length) return NO;
        size = be64(b + offset + 8);
        header = 16;
    } else if (size == 0) {
        size = length - offset;
    }
    if (size < header) return NO;
    out->start = offset;
    out->header = header;
    out->size = size;
    memcpy(out->type, b + offset + 4, 4);
    out->type[4] = 0;
    return YES;
}

// The first box of `type` among the children in [from, to).
static BOOL findChild(const uint8_t *b, NSUInteger length, NSUInteger from, NSUInteger to, const char *type, SCBox *out) {
    NSUInteger at = from;
    SCBox box;
    while (at < to && boxAt(b, length, at, &box)) {
        if (memcmp(box.type, type, 4) == 0) { *out = box; return YES; }
        if (box.size == 0) break;
        at += (NSUInteger)box.size;
    }
    return NO;
}

static BOOL findPath(const uint8_t *b, NSUInteger length, const char *const *path, int depth, SCBox *out) {
    NSUInteger from = 0, to = length;
    SCBox box = {0};
    for (int i = 0; i < depth; i++) {
        if (!findChild(b, length, from, to, path[i], &box)) return NO;
        from = box.start + box.header;
        to = MIN(length, (NSUInteger)(box.start + box.size));
    }
    *out = box;
    return YES;
}

static NSData *boxBytes(NSData *data, SCBox box) {
    if (box.start + box.size > data.length) return nil;
    return [data subdataWithRange:NSMakeRange(box.start, (NSUInteger)box.size)];
}

#pragma mark - the stream

@interface SCFragment : NSObject
@property (nonatomic, strong) NSURL *url;
@property (nonatomic) uint64_t dataOffset, dataLength;  // the frames, inside the segment
@property (nonatomic, strong) NSData *sizes;            // uint32 per frame, host order
@property (nonatomic, strong) NSData *durations;        // uint32 per frame
@property (nonatomic) uint64_t fileOffset;              // where the frames go in the file
@property (nonatomic) uint64_t frameStart, frameCount;  // in the media timescale
@property (nonatomic) BOOL written, loading;
@end
@implementation SCFragment
@end

@interface SCStreamJob : NSObject
@property (nonatomic, strong) SCEntry *entry;
@property (nonatomic, copy) NSString *path, *fileName;
@property (nonatomic) int fd;
@property (nonatomic, strong) NSArray<SCFragment *> *fragments;
@property (nonatomic) uint32_t timescale;
@property (nonatomic) uint64_t fileSize;
@property (nonatomic) NSUInteger priority;
@property (nonatomic) BOOL failed, complete, announced;
@property (nonatomic, strong) NSCondition *condition;
@property (nonatomic, strong) NSMutableArray *playable;
@end
@implementation SCStreamJob
@end

static NSMutableDictionary<NSString *, SCStreamJob *> *gJobsByName;  // file name -> job, under gJobsLock
static NSLock *gJobsLock;

static SCStreamJob *jobForPath(NSString *path) {
    [gJobsLock lock];
    SCStreamJob *job = gJobsByName[path.lastPathComponent];
    [gJobsLock unlock];
    return job;
}

static NSString *safeFileName(NSString *s) {
    NSCharacterSet *bad = [NSCharacterSet characterSetWithCharactersInString:@"/\\:?%*|\"<>\n\r\t"];
    NSString *clean = [[s componentsSeparatedByCharactersInSet:bad] componentsJoinedByString:@" "];
    return clean.length > 120 ? [clean substringToIndex:120] : clean;
}

// iTunes-style tags: meta { hdlr mdir, ilst { ©nam ©ART ©alb ©cmt covr } }.
static NSData *ilstItem(const char *type, uint32_t dataType, NSData *value) {
    NSMutableData *data = [NSMutableData data];
    put32(data, dataType);
    put32(data, 0);
    [data appendData:value];
    return box(type, box("data", data));
}

static NSData *tags(SCEntry *entry, NSData *artwork) {
    NSMutableData *ilst = [NSMutableData data];
    [ilst appendData:ilstItem("\xa9nam", 1, [entry.title dataUsingEncoding:NSUTF8StringEncoding])];
    [ilst appendData:ilstItem("\xa9" "ART", 1, [entry.artist dataUsingEncoding:NSUTF8StringEncoding])];
    [ilst appendData:ilstItem("\xa9" "alb", 1, [SCAlbumName dataUsingEncoding:NSUTF8StringEncoding])];
    [ilst appendData:ilstItem("\xa9" "cmt", 1, [[NSString stringWithFormat:@"SC:%lld", entry.trackID] dataUsingEncoding:NSUTF8StringEncoding])];
    if (artwork.length > 4) {
        const uint8_t *a = artwork.bytes;
        uint32_t kind = (a[0] == 0x89 && a[1] == 'P') ? 14 : 13;  // PNG or JPEG
        [ilst appendData:ilstItem("covr", kind, artwork)];
    }
    NSMutableData *hdlr = [NSMutableData data];
    put32(hdlr, 0);
    [hdlr appendBytes:"mdir" length:4];
    [hdlr appendBytes:"appl" length:4];
    put32(hdlr, 0);
    put32(hdlr, 0);
    [hdlr appendBytes:"\0" length:1];
    NSMutableData *meta = [NSMutableData data];
    [meta appendData:fullbox("hdlr", 0, 0, hdlr)];
    [meta appendData:box("ilst", ilst)];
    return box("udta", fullbox("meta", 0, 0, meta));
}

// mvhd/tkhd/mdhd with a new duration (their layouts differ by version).
static NSData *withDuration(NSData *original, uint64_t duration, NSUInteger v0Offset, NSUInteger v1Offset) {
    NSMutableData *d = [original mutableCopy];
    uint8_t *b = d.mutableBytes;
    BOOL v1 = b[8] == 1;
    NSUInteger at = v1 ? v1Offset : v0Offset;
    if (at + (v1 ? 8 : 4) > d.length) return original;
    if (v1) {
        uint64_t v = CFSwapInt64HostToBig(duration);
        memcpy(b + at, &v, 8);
    } else {
        uint32_t v = CFSwapInt32HostToBig((uint32_t)MIN(duration, (uint64_t)UINT32_MAX));
        memcpy(b + at, &v, 4);
    }
    return d;
}

// The ordinary m4a header for the whole track: ftyp, moov (sample table filled in), mdat's header.
static NSData *header(NSData *init, NSArray<SCFragment *> *fragments, SCEntry *entry, NSData *artwork, uint32_t *outTimescale, uint64_t *outFileSize) {
    const uint8_t *b = init.bytes;
    NSUInteger n = init.length;
    SCBox mvhd, tkhd, mdhd, hdlr, smhd, dinf, stsd;
    const char *pMvhd[] = {"moov", "mvhd"}, *pTkhd[] = {"moov", "trak", "tkhd"}, *pMdhd[] = {"moov", "trak", "mdia", "mdhd"},
               *pHdlr[] = {"moov", "trak", "mdia", "hdlr"}, *pSmhd[] = {"moov", "trak", "mdia", "minf", "smhd"},
               *pDinf[] = {"moov", "trak", "mdia", "minf", "dinf"}, *pStsd[] = {"moov", "trak", "mdia", "minf", "stbl", "stsd"};
    if (!findPath(b, n, pMvhd, 2, &mvhd) || !findPath(b, n, pTkhd, 3, &tkhd) || !findPath(b, n, pMdhd, 4, &mdhd) ||
        !findPath(b, n, pHdlr, 4, &hdlr) || !findPath(b, n, pStsd, 6, &stsd)) return nil;
    BOOL hasSmhd = findPath(b, n, pSmhd, 5, &smhd), hasDinf = findPath(b, n, pDinf, 5, &dinf);
    // Timescales: the movie's from mvhd, the track's from mdhd.
    const uint8_t *mv = b + mvhd.start, *md = b + mdhd.start;
    uint32_t movieScale = mv[8] == 1 ? be32(mv + 28) : be32(mv + 20);
    uint32_t mediaScale = md[8] == 1 ? be32(md + 28) : be32(md + 20);
    if (!movieScale || !mediaScale) return nil;
    uint64_t mediaDuration = 0, frames = 0;
    for (SCFragment *f in fragments) {
        mediaDuration += f.frameCount;
        frames += f.sizes.length / 4;
    }
    uint64_t movieDuration = mediaDuration * movieScale / mediaScale;

    // Sample table: stts (run-length durations), stsc (frames per fragment), stsz, stco (one chunk per fragment).
    NSMutableData *stts = [NSMutableData data], *sttsRuns = [NSMutableData data];
    uint32_t runs = 0, runCount = 0, runDelta = 0;
    for (SCFragment *f in fragments) {
        const uint32_t *d = f.durations.bytes;
        for (NSUInteger i = 0; i < f.durations.length / 4; i++) {
            if (runCount && d[i] == runDelta) { runCount++; continue; }
            if (runCount) { put32(sttsRuns, runCount); put32(sttsRuns, runDelta); runs++; }
            runCount = 1;
            runDelta = d[i];
        }
    }
    if (runCount) { put32(sttsRuns, runCount); put32(sttsRuns, runDelta); runs++; }
    put32(stts, runs);
    [stts appendData:sttsRuns];
    NSMutableData *stsc = [NSMutableData data], *stscRuns = [NSMutableData data];
    uint32_t stscCount = 0, lastPerChunk = UINT32_MAX;
    for (NSUInteger i = 0; i < fragments.count; i++) {
        uint32_t perChunk = (uint32_t)(fragments[i].sizes.length / 4);
        if (perChunk == lastPerChunk) continue;
        put32(stscRuns, (uint32_t)i + 1);
        put32(stscRuns, perChunk);
        put32(stscRuns, 1);
        stscCount++;
        lastPerChunk = perChunk;
    }
    put32(stsc, stscCount);
    [stsc appendData:stscRuns];
    NSMutableData *stsz = [NSMutableData data];
    put32(stsz, 0);
    put32(stsz, (uint32_t)frames);
    uint64_t payload = 0;
    for (SCFragment *f in fragments) {
        const uint32_t *s = f.sizes.bytes;
        for (NSUInteger i = 0; i < f.sizes.length / 4; i++) put32(stsz, s[i]);
        payload += f.dataLength;
    }

    NSData *(^build)(uint64_t) = ^NSData *(uint64_t dataStart) {
        NSMutableData *stco = [NSMutableData data];
        put32(stco, (uint32_t)fragments.count);
        uint64_t at = dataStart;
        for (SCFragment *f in fragments) {
            f.fileOffset = at;
            put32(stco, (uint32_t)at);
            at += f.dataLength;
        }
        NSMutableData *stbl = [NSMutableData data];
        [stbl appendData:boxBytes(init, stsd)];
        [stbl appendData:fullbox("stts", 0, 0, stts)];
        [stbl appendData:fullbox("stsc", 0, 0, stsc)];
        [stbl appendData:fullbox("stsz", 0, 0, stsz)];
        [stbl appendData:fullbox("stco", 0, 0, stco)];
        NSMutableData *minf = [NSMutableData data];
        [minf appendData:hasSmhd ? boxBytes(init, smhd) : fullbox("smhd", 0, 0, [NSMutableData dataWithLength:4])];
        if (hasDinf) [minf appendData:boxBytes(init, dinf)];
        else {
            NSMutableData *dref = [NSMutableData data];
            put32(dref, 1);
            [dref appendData:fullbox("url ", 0, 1, [NSData data])];
            [minf appendData:box("dinf", fullbox("dref", 0, 0, dref))];
        }
        [minf appendData:box("stbl", stbl)];
        NSMutableData *mdia = [NSMutableData data];
        [mdia appendData:withDuration(boxBytes(init, mdhd), mediaDuration, 24, 32)];
        [mdia appendData:boxBytes(init, hdlr)];
        [mdia appendData:box("minf", minf)];
        NSMutableData *trak = [NSMutableData data];
        [trak appendData:withDuration(boxBytes(init, tkhd), movieDuration, 28, 36)];
        [trak appendData:box("mdia", mdia)];
        NSMutableData *moov = [NSMutableData data];
        [moov appendData:withDuration(boxBytes(init, mvhd), movieDuration, 24, 32)];
        [moov appendData:box("trak", trak)];
        [moov appendData:tags(entry, artwork)];
        NSMutableData *ftypPayload = [NSMutableData data];
        [ftypPayload appendBytes:"M4A " length:4];
        put32(ftypPayload, 0);
        [ftypPayload appendBytes:"M4A mp42isom" length:12];
        NSMutableData *head = [NSMutableData data];
        [head appendData:box("ftyp", ftypPayload)];
        [head appendData:box("moov", moov)];
        put32(head, (uint32_t)(payload + 8));
        [head appendBytes:"mdat" length:4];
        return head;
    };
    NSData *draft = build(0);
    NSData *final = build(draft.length);  // stco values do not change its size
    if (final.length != draft.length || payload + final.length > UINT32_MAX) return nil;
    *outTimescale = mediaScale;
    *outFileSize = final.length + payload;
    return final;
}

// A segment's moof (one or more): frame sizes and durations, and where the frames are in the segment.
static BOOL parseFragment(NSData *data, uint32_t defaultDuration, uint32_t defaultSize, SCFragment *f, uint64_t *needMore) {
    const uint8_t *b = data.bytes;
    NSUInteger n = data.length, at = 0;
    SCBox top;
    while (boxAt(b, n, at, &top)) {
        if (memcmp(top.type, "moof", 4) == 0) {
            if (top.start + top.size > n) { *needMore = top.start + top.size; return NO; }
            NSUInteger moofEnd = (NSUInteger)(top.start + top.size);
            SCBox traf, tfhd, trun;
            if (!findChild(b, n, top.start + top.header, moofEnd, "traf", &traf)) return NO;
            NSUInteger trafFrom = traf.start + traf.header, trafTo = (NSUInteger)(traf.start + traf.size);
            if (!findChild(b, n, trafFrom, trafTo, "tfhd", &tfhd) || !findChild(b, n, trafFrom, trafTo, "trun", &trun)) return NO;
            const uint8_t *h = b + tfhd.start + tfhd.header;
            uint32_t hflags = be32(h) & 0xffffff;
            NSUInteger p = 8;  // version/flags, track_ID
            uint64_t base = top.start;
            if (hflags & 0x01) { base = be64(h + p); p += 8; }
            if (hflags & 0x02) p += 4;
            uint32_t dDur = defaultDuration, dSize = defaultSize;
            if (hflags & 0x08) { dDur = be32(h + p); p += 4; }
            if (hflags & 0x10) { dSize = be32(h + p); p += 4; }
            const uint8_t *r = b + trun.start + trun.header;
            uint32_t rflags = be32(r) & 0xffffff, count = be32(r + 4);
            NSUInteger q = 8;
            int32_t dataOffset = 0;
            if (rflags & 0x01) { dataOffset = (int32_t)be32(r + q); q += 4; }
            if (rflags & 0x04) q += 4;
            NSUInteger per = ((rflags & 0x100) ? 4 : 0) + ((rflags & 0x200) ? 4 : 0) + ((rflags & 0x400) ? 4 : 0) + ((rflags & 0x800) ? 4 : 0);
            if (trun.header + q + (uint64_t)per * count > trun.size) return NO;
            NSMutableData *sizes = [NSMutableData dataWithLength:count * 4], *durations = [NSMutableData dataWithLength:count * 4];
            uint32_t *S = sizes.mutableBytes, *D = durations.mutableBytes;
            uint64_t total = 0, frames = 0;
            for (uint32_t i = 0; i < count; i++) {
                const uint8_t *e = r + q + (NSUInteger)i * per;
                NSUInteger k = 0;
                D[i] = (rflags & 0x100) ? be32(e + k) : dDur;
                if (rflags & 0x100) k += 4;
                S[i] = (rflags & 0x200) ? be32(e + k) : dSize;
                total += S[i];
                frames += D[i];
            }
            if (!total || !frames) return NO;
            // Several moofs in one segment are joined only when their data is back to back.
            uint64_t start = base + (uint64_t)dataOffset;
            if (f.sizes && start != f.dataOffset + f.dataLength) return NO;
            if (!f.sizes) {
                f.dataOffset = start;
                f.sizes = sizes;
                f.durations = durations;
            } else {
                NSMutableData *ms = [f.sizes mutableCopy], *md = [f.durations mutableCopy];
                [ms appendData:sizes];
                [md appendData:durations];
                f.sizes = ms;
                f.durations = md;
            }
            f.dataLength += total;
            f.frameCount += frames;
            at = moofEnd;
            continue;
        }
        if (memcmp(top.type, "mdat", 4) == 0) {
            uint64_t next = top.start + top.size;
            if (next >= *needMore) return f.sizes != nil;  // *needMore holds the segment's size here
            if (next + 8 > n) { *needMore = next + 4096; return NO; }
            at = (NSUInteger)next;
            continue;
        }
        at = (NSUInteger)(top.start + top.size);
        if (at > n) break;
    }
    return f.sizes != nil;
}

@implementation SCStream {
    dispatch_queue_t _queue;
    NSMutableDictionary<NSNumber *, SCStreamJob *> *_jobs;
}

+ (instancetype)shared {
    static SCStream *s;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ s = [self new]; });
    return s;
}

- (instancetype)init {
    if ((self = [super init])) {
        _queue = dispatch_queue_create("spotcloud.stream", DISPATCH_QUEUE_SERIAL);
        _jobs = [NSMutableDictionary dictionary];
        gJobsByName = [NSMutableDictionary dictionary];
        gJobsLock = [NSLock new];
    }
    return self;
}

- (void)startEntry:(SCEntry *)entry playable:(void (^)(NSString *, NSError *))playable {
    NSString *existing = [SCLibrary.shared pathForEntry:entry];
    if (existing) {
        [SCLibrary.shared touch:entry];
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{ playable(existing, nil); });
        return;
    }
    dispatch_async(_queue, ^{
        SCStreamJob *job = self->_jobs[@(entry.trackID)];
        if (job) {
            if (job.failed) { dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{ playable(nil, streamError(@"stream failed")); }); return; }
            if (job.announced) { dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{ playable(job.path, nil); }); return; }
            [job.playable addObject:playable];
            return;
        }
        job = [SCStreamJob new];
        job.entry = entry;
        job.fd = -1;
        job.condition = [NSCondition new];
        job.playable = [NSMutableArray arrayWithObject:playable];
        self->_jobs[@(entry.trackID)] = job;
        SCLog(@"stream", @"start %lld \"%@\"", entry.trackID, entry.title);
        [self prepare:job];
    });
}

- (void)announce:(SCStreamJob *)job path:(NSString *)path error:(NSError *)error {
    dispatch_async(_queue, ^{
        if (job.announced) return;
        job.announced = YES;
        NSArray *waiters = [job.playable copy];
        [job.playable removeAllObjects];
        for (void (^w)(NSString *, NSError *) in waiters) {
            dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{ w(path, error); });
        }
    });
}

- (void)fail:(SCStreamJob *)job error:(NSError *)error {
    SCLog(@"stream", @"failed %lld: %@", job.entry.trackID, error.localizedDescription);
    [job.condition lock];
    job.failed = YES;
    [job.condition broadcast];
    [job.condition unlock];
    if (job.fd >= 0) { close(job.fd); job.fd = -1; }
    if (job.path) [NSFileManager.defaultManager removeItemAtPath:job.path error:nil];
    [gJobsLock lock];
    if (job.fileName) [gJobsByName removeObjectForKey:job.fileName];
    [gJobsLock unlock];
    [self announce:job path:nil error:error];
    dispatch_async(_queue, ^{ [self->_jobs removeObjectForKey:@(job.entry.trackID)]; });
}

// Falls back to downloading the whole track (MP3 streams, or anything the fMP4 path cannot read).
- (void)wholeDownload:(SCStreamJob *)job reason:(NSString *)reason {
    SCLog(@"stream", @"%lld: %@; downloading it whole", job.entry.trackID, reason);
    [SCDownloader.shared ensureEntry:job.entry completion:^(NSString *path, NSError *error) {
        [self announce:job path:path error:error];
        dispatch_async(self->_queue, ^{ [self->_jobs removeObjectForKey:@(job.entry.trackID)]; });
    }];
}

- (void)prepare:(SCStreamJob *)job {
    SCClient *client = SCClient.shared;
    [client trackWithID:job.entry.trackID completion:^(SCTrack *track, NSError *error) {
        if (!track || !SCTrackIsPlayable(track)) { [self fail:job error:error ?: streamError(@"Go+, encrypted or a preview")]; return; }
        SCTranscoding *t = SCBestTranscoding(track);
        if (![t.protocol isEqualToString:@"hls"] || !t.isAAC) { [self wholeDownload:job reason:@"not an AAC HLS stream"]; return; }
        [client streamURLForTranscoding:t track:track completion:^(NSURL *url, NSError *streamErr) {
            if (!url) { [self fail:job error:streamErr ?: streamError(@"no stream")]; return; }
            [client fetch:url completion:^(NSData *data, NSError *playlistErr) {
                NSString *text = data ? [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] : nil;
                if (!text) { [self fail:job error:playlistErr ?: streamError(@"no playlist")]; return; }
                [self readPlaylist:text base:url job:job];
            }];
        }];
    }];
}

- (void)readPlaylist:(NSString *)text base:(NSURL *)base job:(SCStreamJob *)job {
    NSURL *initURL = nil;
    NSMutableArray<SCFragment *> *fragments = [NSMutableArray array];
    for (NSString *raw in [text componentsSeparatedByCharactersInSet:NSCharacterSet.newlineCharacterSet]) {
        NSString *line = [raw stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
        if ([line hasPrefix:@"#EXT-X-KEY"] && ![line containsString:@"METHOD=NONE"]) { [self fail:job error:streamError(@"encrypted stream")]; return; }
        if ([line hasPrefix:@"#EXT-X-BYTERANGE"]) { [self wholeDownload:job reason:@"byte-range playlist"]; return; }
        if ([line hasPrefix:@"#EXT-X-MAP:"]) {
            NSRange uri = [line rangeOfString:@"URI=\""];
            NSString *rest = uri.location != NSNotFound ? [line substringFromIndex:NSMaxRange(uri)] : nil;
            NSRange end = rest ? [rest rangeOfString:@"\""] : NSMakeRange(NSNotFound, 0);
            if (end.location != NSNotFound) initURL = [NSURL URLWithString:[rest substringToIndex:end.location] relativeToURL:base].absoluteURL;
            continue;
        }
        if (line.length && ![line hasPrefix:@"#"]) {
            SCFragment *f = [SCFragment new];
            f.url = [NSURL URLWithString:line relativeToURL:base].absoluteURL;
            [fragments addObject:f];
        }
    }
    if (!initURL || !fragments.count) { [self wholeDownload:job reason:@"no fMP4 init segment"]; return; }
    SCClient *client = SCClient.shared;
    [client fetch:initURL completion:^(NSData *init, NSError *error) {
        if (!init.length) { [self fail:job error:error ?: streamError(@"no init segment")]; return; }
        // Defaults for frames a fragment does not size itself: trex in the init segment.
        uint32_t defDuration = 1024, defSize = 0;
        SCBox trex;
        const char *pTrex[] = {"moov", "mvex", "trex"};
        if (findPath(init.bytes, init.length, pTrex, 3, &trex) && trex.size >= 32) {
            const uint8_t *t = (const uint8_t *)init.bytes + trex.start;
            defDuration = be32(t + 20) ?: 1024;
            defSize = be32(t + 24);
        }
        dispatch_group_t group = dispatch_group_create();
        __block BOOL bad = NO;
        NSLock *lock = [NSLock new];
        dispatch_semaphore_t slots = dispatch_semaphore_create(8);
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
            for (SCFragment *f in fragments) {
                dispatch_semaphore_wait(slots, DISPATCH_TIME_FOREVER);
                dispatch_group_enter(group);
                [self readHead:f length:8192 defDuration:defDuration defSize:defSize attempt:0 done:^(BOOL ok) {
                    if (!ok) { [lock lock]; bad = YES; [lock unlock]; }
                    dispatch_semaphore_signal(slots);
                    dispatch_group_leave(group);
                }];
            }
            __block NSData *artwork = nil;
            NSURL *art = job.entry.artworkURL ? [NSURL URLWithString:job.entry.artworkURL] : nil;
            if (art) {
                dispatch_group_enter(group);
                [client fetch:art completion:^(NSData *d, NSError *e) { artwork = d; dispatch_group_leave(group); }];
            }
            dispatch_group_notify(group, dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
                if (bad) { [self wholeDownload:job reason:@"a fragment could not be read"]; return; }
                [self writeHeaderFor:job init:init fragments:fragments artwork:artwork];
            });
        });
    }];
}

// The start of a segment, as much as its moof(s) need.
- (void)readHead:(SCFragment *)f length:(uint64_t)length defDuration:(uint32_t)dd defSize:(uint32_t)ds attempt:(int)attempt done:(void (^)(BOOL))done {
    [SCClient.shared fetch:f.url offset:0 length:length completion:^(NSData *data, unsigned long long total, BOOL whole, NSError *error) {
        if (!data) { done(NO); return; }
        f.sizes = nil;
        f.durations = nil;
        f.dataLength = 0;
        f.frameCount = 0;
        uint64_t need = total;
        BOOL ok = parseFragment(data, dd, ds, f, &need);
        if (!ok && !whole && need > data.length && need <= total && attempt < 3) {
            [self readHead:f length:MIN(need + 4096, total) defDuration:dd defSize:ds attempt:attempt + 1 done:done];
            return;
        }
        if (ok && f.dataOffset + f.dataLength > total) ok = NO;
        done(ok);
    }];
}

- (void)writeHeaderFor:(SCStreamJob *)job init:(NSData *)init fragments:(NSArray<SCFragment *> *)fragments artwork:(NSData *)artwork {
    uint32_t timescale = 0;
    uint64_t fileSize = 0;
    NSData *head = header(init, fragments, job.entry, artwork, &timescale, &fileSize);
    if (!head) { [self wholeDownload:job reason:@"could not build the m4a header"]; return; }
    uint64_t frameAt = 0;
    for (SCFragment *f in fragments) {
        f.frameStart = frameAt;
        frameAt += f.frameCount;
    }
    job.fragments = fragments;
    job.timescale = timescale;
    job.fileSize = fileSize;
    NSString *base = safeFileName([NSString stringWithFormat:@"%@ - %@ [%lld]", job.entry.artist, job.entry.title, job.entry.trackID]);
    job.fileName = [base stringByAppendingPathExtension:@"m4a"];
    job.path = [SCLibrary.shared.tracksDirectory stringByAppendingPathComponent:job.fileName];
    // Built aside and moved in whole, so Spotify's scanner never sees half a header.
    NSString *partial = [NSTemporaryDirectory() stringByAppendingPathComponent:[@"spotcloud-" stringByAppendingString:job.fileName]];
    [NSFileManager.defaultManager removeItemAtPath:partial error:nil];
    int fd = open(partial.fileSystemRepresentation, O_RDWR | O_CREAT | O_TRUNC, 0644);
    if (fd < 0 || pwrite(fd, head.bytes, head.length, 0) != (ssize_t)head.length || ftruncate(fd, (off_t)fileSize) != 0) {
        if (fd >= 0) close(fd);
        [self fail:job error:streamError(@"could not create the file")];
        return;
    }
    [NSFileManager.defaultManager removeItemAtPath:job.path error:nil];
    if (rename(partial.fileSystemRepresentation, job.path.fileSystemRepresentation) != 0) {
        close(fd);
        [self fail:job error:streamError(@"could not move the file in")];
        return;
    }
    job.fd = fd;
    [gJobsLock lock];
    gJobsByName[job.fileName] = job;
    [gJobsLock unlock];
    SCLog(@"stream", @"%lld: %lu fragments, %.0f s, %.1f MB, header written", job.entry.trackID, (unsigned long)fragments.count,
          (double)frameAt / timescale, fileSize / 1048576.0);
    for (int i = 0; i < 4; i++) [self nextFragment:job];
}

- (SCFragment *)takeFragment:(SCStreamJob *)job {
    [job.condition lock];
    SCFragment *pick = nil;
    NSUInteger count = job.fragments.count;
    for (NSUInteger k = 0; k < count && !pick; k++) {
        SCFragment *f = job.fragments[(job.priority + k) % count];
        if (!f.written && !f.loading) pick = f;
    }
    pick.loading = YES;
    [job.condition unlock];
    return pick;
}

- (void)nextFragment:(SCStreamJob *)job {
    if (job.failed) return;
    SCFragment *f = [self takeFragment:job];
    if (!f) return;
    [SCClient.shared fetch:f.url offset:f.dataOffset length:f.dataLength completion:^(NSData *data, unsigned long long total, BOOL whole, NSError *error) {
        NSData *frames = data;
        if (whole && data.length >= f.dataOffset + f.dataLength) frames = [data subdataWithRange:NSMakeRange((NSUInteger)f.dataOffset, (NSUInteger)f.dataLength)];
        if (!frames || frames.length != f.dataLength) {
            [self fail:job error:error ?: streamError(@"a fragment did not arrive whole")];
            return;
        }
        if (job.failed || pwrite(job.fd, frames.bytes, frames.length, (off_t)f.fileOffset) != (ssize_t)frames.length) {
            if (!job.failed) [self fail:job error:streamError(@"could not write the file")];
            return;
        }
        [job.condition lock];
        f.written = YES;
        f.loading = NO;
        BOOL all = YES;
        NSUInteger prefix = 0;
        for (SCFragment *g in job.fragments) {
            if (!g.written) { all = NO; break; }
            prefix++;
        }
        if (all) job.complete = YES;
        [job.condition broadcast];
        [job.condition unlock];
        // Playable with the first two fragments (~20 s) in place; the rest arrives faster than it plays.
        if (prefix >= MIN((NSUInteger)2, job.fragments.count)) [self announce:job path:job.path error:nil];
        if (all) [self finish:job];
        else [self nextFragment:job];
    }];
}

- (void)finish:(SCStreamJob *)job {
    fsync(job.fd);
    close(job.fd);
    job.fd = -1;
    [SCLibrary.shared entry:job.entry savedAs:job.fileName size:job.fileSize];
    SCLog(@"stream", @"%lld complete (%.1f MB)", job.entry.trackID, job.fileSize / 1048576.0);
    // The guard keeps the job while Spotify has the file open; reads no longer wait once complete.
    dispatch_async(_queue, ^{ [self->_jobs removeObjectForKey:@(job.entry.trackID)]; });
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 60 * NSEC_PER_SEC), dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        [gJobsLock lock];
        if (gJobsByName[job.fileName] == job) [gJobsByName removeObjectForKey:job.fileName];
        [gJobsLock unlock];
    });
}

@end

#pragma mark - the ExtAudioFile guard

static OSStatus (*gOpenURL)(CFURLRef, ExtAudioFileRef *);
static OSStatus (*gRead)(ExtAudioFileRef, UInt32 *, AudioBufferList *);
static OSStatus (*gSeek)(ExtAudioFileRef, SInt64);
static OSStatus (*gDispose)(ExtAudioFileRef);
static NSMapTable *gOpenFiles;  // ExtAudioFileRef (as pointer) -> job
static NSLock *gOpenLock;

static SCStreamJob *jobForRef(ExtAudioFileRef ref) {
    [gOpenLock lock];
    SCStreamJob *job = (__bridge SCStreamJob *)NSMapGet(gOpenFiles, ref);
    [gOpenLock unlock];
    return job;
}

static NSUInteger fragmentForFrame(SCStreamJob *job, uint64_t frame) {
    NSArray<SCFragment *> *fs = job.fragments;
    NSUInteger lo = 0, hi = fs.count;
    while (hi - lo > 1) {
        NSUInteger mid = (lo + hi) / 2;
        if (fs[mid].frameStart <= frame) lo = mid; else hi = mid;
    }
    return lo;
}

// Blocks until every fragment from `first` to `last` is on disk (or the stream failed, or 30 s passed).
static void waitFor(SCStreamJob *job, NSUInteger first, NSUInteger last) {
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:30];
    BOOL logged = NO;
    [job.condition lock];
    while (!job.complete && !job.failed) {
        BOOL ready = YES;
        for (NSUInteger i = first; i <= last && i < job.fragments.count; i++) {
            if (!job.fragments[i].written) { ready = NO; break; }
        }
        if (ready) break;
        if (!logged) {
            job.priority = first;
            logged = YES;
            SCLog(@"stream", @"%lld: the player waits for fragments %lu-%lu", job.entry.trackID, (unsigned long)first, (unsigned long)last);
        }
        if (![job.condition waitUntilDate:deadline]) break;
    }
    [job.condition unlock];
}

static OSStatus guardOpen(CFURLRef url, ExtAudioFileRef *out) {
    OSStatus status = gOpenURL(url, out);
    if (status == noErr && out && *out) {
        NSString *path = [(__bridge NSURL *)url path];
        SCStreamJob *job = path ? jobForPath(path) : nil;
        if (job) {
            [gOpenLock lock];
            NSMapInsert(gOpenFiles, *out, (__bridge void *)job);
            [gOpenLock unlock];
            SCLog(@"stream", @"%lld opened by the player while %@", job.entry.trackID, job.complete ? @"complete" : @"streaming");
        }
    }
    return status;
}

static OSStatus guardRead(ExtAudioFileRef ref, UInt32 *frames, AudioBufferList *data) {
    SCStreamJob *job = jobForRef(ref);
    if (job && !job.complete && !job.failed && frames) {
        SInt64 position = 0;
        AudioStreamBasicDescription file = {0}, client = {0};
        UInt32 size = sizeof file;
        ExtAudioFileTell(ref, &position);
        ExtAudioFileGetProperty(ref, kExtAudioFileProperty_FileDataFormat, &size, &file);
        size = sizeof client;
        ExtAudioFileGetProperty(ref, kExtAudioFileProperty_ClientDataFormat, &size, &client);
        double ratio = (file.mSampleRate > 0 && client.mSampleRate > 0) ? file.mSampleRate / client.mSampleRate : 1;
        uint64_t from = (uint64_t)MAX((SInt64)0, position);
        uint64_t to = from + (uint64_t)(*frames * ratio) + 8192;
        NSUInteger first = fragmentForFrame(job, from), last = MIN(fragmentForFrame(job, to) + 1, job.fragments.count - 1);
        waitFor(job, first, last);
    }
    return gRead(ref, frames, data);
}

static OSStatus guardSeek(ExtAudioFileRef ref, SInt64 frame) {
    SCStreamJob *job = jobForRef(ref);
    if (job && !job.complete && frame >= 0) {
        [job.condition lock];
        job.priority = fragmentForFrame(job, (uint64_t)frame);
        [job.condition unlock];
    }
    return gSeek(ref, frame);
}

static OSStatus guardDispose(ExtAudioFileRef ref) {
    [gOpenLock lock];
    NSMapRemove(gOpenFiles, ref);
    [gOpenLock unlock];
    return gDispose(ref);
}

void SCStreamGuardStart(void) {
    gOpenFiles = [NSMapTable mapTableWithKeyOptions:NSPointerFunctionsOpaqueMemory | NSPointerFunctionsOpaquePersonality
                                       valueOptions:NSPointerFunctionsStrongMemory];
    gOpenLock = [NSLock new];
    (void)SCStream.shared;
    BOOL open = SCRebindImport("ExtAudioFileOpenURL", (void *)guardOpen, (void **)&gOpenURL) && gOpenURL;
    BOOL read = SCRebindImport("ExtAudioFileRead", (void *)guardRead, (void **)&gRead) && gRead;
    BOOL seek = SCRebindImport("ExtAudioFileSeek", (void *)guardSeek, (void **)&gSeek) && gSeek;
    BOOL dispose = SCRebindImport("ExtAudioFileDispose", (void *)guardDispose, (void **)&gDispose) && gDispose;
    SCLog(@"stream", @"player read guard: open %d read %d seek %d dispose %d", open, read, seek, dispose);
}
