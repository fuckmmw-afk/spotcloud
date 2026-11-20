#import "SCFilter.h"

static BOOL usable(SCTranscoding *t) {
    if (t.snipped || t.encrypted) return NO;
    if (![t.protocol isEqualToString:@"hls"] && ![t.protocol isEqualToString:@"progressive"]) return NO;
    return t.isAAC || t.isMP3;
}

SCTranscoding *SCBestTranscoding(SCTrack *track) {
    SCTranscoding *best = nil;
    int bestRank = INT_MAX;
    for (SCTranscoding *t in track.transcodings) {
        if (!usable(t)) continue;
        BOOL hls = [t.protocol isEqualToString:@"hls"];
        int rank = t.isAAC && hls ? 0 : (t.isMP3 && hls ? 1 : (t.isMP3 ? 2 : 3));
        if (rank < bestRank) {
            best = t;
            bestRank = rank;
        }
    }
    return best;
}

BOOL SCTrackIsPlayable(SCTrack *track) {
    if (!track.streamable) return NO;
    NSString *policy = track.policy.uppercaseString ?: @"";
    if ([policy isEqualToString:@"SNIP"] || [policy isEqualToString:@"BLOCK"]) return NO;
    // A preview: what plays is shorter than the upload.
    if (track.fullDuration > 0 && track.duration > 0 && track.fullDuration - track.duration > 1.5) return NO;
    if (track.duration < 1) return NO;
    return SCBestTranscoding(track) != nil;
}
