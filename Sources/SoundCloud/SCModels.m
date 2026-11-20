#import "SCModels.h"

NSString *const SCTitleMark = @" (SC)";

static NSString *str(id value) { return [value isKindOfClass:NSString.class] ? value : nil; }
static NSNumber *num(id value) { return [value isKindOfClass:NSNumber.class] ? value : nil; }
static NSDictionary *dict(id value) { return [value isKindOfClass:NSDictionary.class] ? value : nil; }

@implementation SCTranscoding
+ (instancetype)transcodingWithJSON:(NSDictionary *)json {
    NSString *url = str(json[@"url"]);
    NSDictionary *format = dict(json[@"format"]);
    if (!url || !format) return nil;
    SCTranscoding *t = [self new];
    t.url = url;
    t.protocol = str(format[@"protocol"]) ?: @"";
    t.mimeType = str(format[@"mime_type"]) ?: @"";
    t.preset = str(json[@"preset"]) ?: @"";
    t.quality = str(json[@"quality"]) ?: @"";
    t.snipped = [num(json[@"snipped"]) boolValue];
    return t;
}
- (BOOL)encrypted { return [self.protocol containsString:@"encrypted"] || [self.protocol hasPrefix:@"cbc"] || [self.protocol hasPrefix:@"ctr"]; }
- (BOOL)isAAC { return [self.mimeType hasPrefix:@"audio/mp4"] || [self.mimeType containsString:@"mp4a"]; }
- (BOOL)isMP3 { return [self.mimeType hasPrefix:@"audio/mpeg"]; }
@end

@implementation SCTrack

+ (instancetype)trackWithJSON:(NSDictionary *)json {
    if (![json isKindOfClass:NSDictionary.class]) return nil;
    if (str(json[@"kind"]) && ![json[@"kind"] isEqualToString:@"track"]) return nil;
    NSNumber *identifier = num(json[@"id"]);
    NSString *title = str(json[@"title"]);
    if (!identifier || !title.length) return nil;
    SCTrack *t = [self new];
    t.trackID = identifier.longLongValue;
    t.title = title;
    t.username = str(dict(json[@"user"])[@"username"]) ?: @"";
    NSString *publisher = str(dict(json[@"publisher_metadata"])[@"artist"]);
    t.publisherArtist = publisher.length ? publisher : nil;
    t.permalinkURL = str(json[@"permalink_url"]);
    NSString *art = str(json[@"artwork_url"]) ?: str(dict(json[@"user"])[@"avatar_url"]);
    t.artworkURL = [art stringByReplacingOccurrencesOfString:@"-large." withString:@"-t500x500."];
    t.trackAuthorization = str(json[@"track_authorization"]);
    t.policy = str(json[@"policy"]);
    t.monetizationModel = str(json[@"monetization_model"]);
    t.duration = num(json[@"duration"]).doubleValue / 1000.0;
    t.fullDuration = (num(json[@"full_duration"]) ?: num(json[@"duration"])).doubleValue / 1000.0;
    t.playbackCount = num(json[@"playback_count"]).longLongValue;
    t.streamable = json[@"streamable"] ? [num(json[@"streamable"]) boolValue] : YES;
    NSMutableArray *transcodings = [NSMutableArray array];
    id list = dict(json[@"media"])[@"transcodings"];
    if ([list isKindOfClass:NSArray.class]) {
        for (id entry in list) {
            SCTranscoding *transcoding = [entry isKindOfClass:NSDictionary.class] ? [SCTranscoding transcodingWithJSON:entry] : nil;
            if (transcoding) [transcodings addObject:transcoding];
        }
    }
    t.transcodings = transcodings;
    return t;
}

// "Artist - Title" (also with an en or em dash), when the upload is named that way.
- (NSRange)artistSeparator {
    for (NSString *dash in @[@" - ", @" – ", @" — "]) {
        NSRange range = [self.title rangeOfString:dash];
        if (range.location != NSNotFound && range.location > 0) return range;
    }
    return NSMakeRange(NSNotFound, 0);
}

- (NSString *)explicitArtist {
    if (self.publisherArtist) return self.publisherArtist;
    NSRange dash = [self artistSeparator];
    if (dash.location == NSNotFound) return nil;
    NSString *artist = [[self.title substringToIndex:dash.location] stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
    return artist.length ? artist : nil;
}

- (NSString *)displayArtist {
    return self.explicitArtist ?: (self.username.length ? self.username : @"SoundCloud");
}

- (NSString *)displayTitle {
    NSRange dash = [self artistSeparator];
    if (dash.location == NSNotFound) return self.title;
    NSString *artist = [[self.title substringToIndex:dash.location] stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
    if (self.publisherArtist && [artist caseInsensitiveCompare:self.publisherArtist] != NSOrderedSame) return self.title;
    NSString *rest = [[self.title substringFromIndex:NSMaxRange(dash)] stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
    return rest.length ? rest : self.title;
}

- (NSString *)markedTitle { return [self.displayTitle stringByAppendingString:SCTitleMark]; }

@end
