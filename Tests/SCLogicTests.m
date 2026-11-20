// Host tests for the pure logic (filter, dedup, models). Built and run on macOS by CI:
//   clang -fobjc-arc -framework Foundation -ISources/SoundCloud Tests/SCLogicTests.m Sources/SoundCloud/SC{Models,Filter,Dedup}.m -o /tmp/t && /tmp/t
#import <Foundation/Foundation.h>
#import "SCModels.h"
#import "SCFilter.h"
#import "SCDedup.h"

static int failures = 0;
#define CHECK(cond) do { if (!(cond)) { failures++; fprintf(stderr, "FAIL %s:%d %s\n", __FILE__, __LINE__, #cond); } } while (0)

static NSDictionary *hls(NSString *protocol, NSString *mime, BOOL snipped) {
    return @{@"url": @"https://api-v2.soundcloud.com/media/x/stream/hls", @"preset": @"aac_160k", @"snipped": @(snipped),
             @"format": @{@"protocol": protocol, @"mime_type": mime}};
}

static SCTrack *track(long long identifier, NSString *title, NSString *user, double seconds, long long plays, NSArray *transcodings) {
    return [SCTrack trackWithJSON:@{@"kind": @"track", @"id": @(identifier), @"title": title, @"user": @{@"username": user},
                                    @"duration": @(seconds * 1000), @"full_duration": @(seconds * 1000), @"playback_count": @(plays),
                                    @"policy": @"MONETIZE", @"streamable": @YES,
                                    @"media": @{@"transcodings": transcodings ?: @[hls(@"hls", @"audio/mp4; codecs=\"mp4a.40.2\"", NO)]}}];
}

int main(void) {
    @autoreleasepool {
        // Normalization
        CHECK([SCNormalizedTitle(@"Skrillex - Bangarang (Official Video) 🔥🔥", @"Skrillex", @"skrillex") isEqualToString:@"bangarang"]);
        CHECK([SCNormalizedTitle(@"Night Drive [FREE DL]", nil, nil) isEqualToString:@"night drive"]);
        CHECK([SCNormalizedTitle(@"Night Drive (prod. by Somebody)", nil, nil) isEqualToString:@"night drive"]);
        CHECK([SCNormalizedTitle(@"Night Drive prod. Somebody", nil, nil) isEqualToString:@"night drive"]);
        CHECK([SCNormalizedTitle(@"NIGHT DRIVE ft. Guest", nil, nil) isEqualToString:@"night drive"]);
        CHECK([SCNormalizedTitle(@"Ночной Город (official audio)", nil, nil) isEqualToString:@"ночнои город"] ||
              [SCNormalizedTitle(@"Ночной Город (official audio)", nil, nil) isEqualToString:@"ночной город"]);

        // Variants never join their original
        CHECK([SCVariantTags(@"Song") isEqualToString:@""]);
        CHECK([SCVariantTags(@"Song (X Remix)") isEqualToString:@"remix"]);
        CHECK([SCVariantTags(@"Song - sped up") isEqualToString:@"spedup"]);
        CHECK([SCVariantTags(@"Song (slowed + reverb)") isEqualToString:@"slowed"]);
        CHECK([SCVariantTags(@"Song VIP") isEqualToString:@"vip"]);
        CHECK([SCVariantTags(@"Song (Bootleg) [Mashup]") isEqualToString:@"bootleg+mashup"]);
        CHECK(![SCVariantTags(@"Vipassana") length]);

        SCTrack *original = track(1, @"Artist - Song", @"Artist", 200, 1000, nil);
        SCTrack *reupload = track(2, @"Song (Official Audio) 🔥", @"music fan", 201.5, 50000, nil);
        SCTrack *remix = track(3, @"Song (Someone Remix)", @"someone", 200, 90000, nil);
        SCTrack *spedUp = track(4, @"Song (sped up)", @"tiktok", 199, 90000, nil);
        SCTrack *longer = track(5, @"Song", @"another", 230, 10, nil);
        SCTrack *other = track(6, @"Completely Different", @"Artist", 200, 10, nil);
        CHECK(SCTracksAreDuplicates(original, reupload));
        CHECK(!SCTracksAreDuplicates(original, remix));
        CHECK(!SCTracksAreDuplicates(original, spedUp));
        CHECK(!SCTracksAreDuplicates(original, longer));
        CHECK(!SCTracksAreDuplicates(original, other));

        // The artist's own upload wins over a more played reupload; otherwise the most played.
        NSArray *kept = SCDeduplicate(@[reupload, original, remix, spedUp, longer, other]);
        CHECK(kept.count == 5);
        CHECK([kept containsObject:original] && ![kept containsObject:reupload]);
        SCTrack *a = track(7, @"Tune", @"fan one", 180, 10, nil), *b = track(8, @"Tune (Free DL)", @"fan two", 181, 999, nil);
        NSArray *pair = SCDeduplicate(@[a, b]);
        CHECK(pair.count == 1 && pair.firstObject == b);

        // Display
        CHECK([original.displayArtist isEqualToString:@"Artist"]);
        CHECK([original.markedTitle isEqualToString:@"Song (SC)"]);
        CHECK([reupload.displayArtist isEqualToString:@"music fan"]);

        // Filter: Go+/encrypted/previews hidden
        CHECK(SCTrackIsPlayable(original));
        SCTrack *encrypted = track(9, @"Label", @"label", 200, 1, @[hls(@"cbc-encrypted-hls", @"audio/mp4", NO), hls(@"ctr-encrypted-hls", @"audio/mp4", NO)]);
        CHECK(!SCTrackIsPlayable(encrypted));
        SCTrack *snippet = track(10, @"Go+", @"label", 30, 1, @[hls(@"hls", @"audio/mp4", YES)]);
        CHECK(!SCTrackIsPlayable(snippet));
        SCTrack *snipPolicy = [SCTrack trackWithJSON:@{@"id": @11, @"title": @"x", @"duration": @30000, @"full_duration": @200000,
                                                       @"policy": @"SNIP", @"media": @{@"transcodings": @[hls(@"hls", @"audio/mp4", NO)]}}];
        CHECK(!SCTrackIsPlayable(snipPolicy));
        SCTrack *mp3 = track(12, @"Old", @"u", 100, 1, @[hls(@"hls", @"audio/mpeg", NO), hls(@"hls", @"audio/mp4", NO)]);
        CHECK(SCBestTranscoding(mp3).isAAC);
    }
    if (failures) { fprintf(stderr, "%d failed\n", failures); return 1; }
    puts("all logic tests passed");
    return 0;
}
