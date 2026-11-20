#import "SCDedup.h"

static NSString *replacing(NSString *text, NSString *pattern, NSString *with) {
    NSError *error = nil;
    NSRegularExpression *re = [NSRegularExpression regularExpressionWithPattern:pattern
                                                                       options:NSRegularExpressionCaseInsensitive error:&error];
    if (!re) return text;
    return [re stringByReplacingMatchesInString:text options:0 range:NSMakeRange(0, text.length) withTemplate:with];
}

static NSString *withoutEmoji(NSString *text) {
    NSMutableString *out = [NSMutableString stringWithCapacity:text.length];
    [text enumerateSubstringsInRange:NSMakeRange(0, text.length) options:NSStringEnumerationByComposedCharacterSequences
                          usingBlock:^(NSString *piece, NSRange r, NSRange e, BOOL *stop) {
        UTF32Char c = 0;
        if (![piece getBytes:&c maxLength:4 usedLength:NULL encoding:NSUTF32LittleEndianStringEncoding options:0
                       range:NSMakeRange(0, piece.length) remainingRange:NULL]) {
            [out appendString:piece];
            return;
        }
        BOOL emoji = (c >= 0x1F000 && c <= 0x1FAFF) || (c >= 0x2600 && c <= 0x27BF) || (c >= 0x2B00 && c <= 0x2BFF) ||
                     (c >= 0x1F1E6 && c <= 0x1F1FF) || c == 0xFE0F || c == 0x200D || (c >= 0x2190 && c <= 0x21FF) ||
                     (c >= 0x2300 && c <= 0x23FF) || (c >= 0x25A0 && c <= 0x25FF) || c == 0x2605 || c == 0x2606;
        if (!emoji) [out appendString:piece];
        else [out appendString:@" "];
    }];
    return out;
}

static NSString *squeezed(NSString *text) {
    NSArray *parts = [text componentsSeparatedByCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    return [[parts filteredArrayUsingPredicate:[NSPredicate predicateWithFormat:@"length > 0"]] componentsJoinedByString:@" "];
}

static NSString *escaped(NSString *text) { return [NSRegularExpression escapedPatternForString:text]; }

NSString *SCNormalizedTitle(NSString *title, NSString *artist, NSString *username) {
    NSString *t = [withoutEmoji(title ?: @"") lowercaseString];
    t = [t stringByFoldingWithOptions:NSDiacriticInsensitiveSearch | NSWidthInsensitiveSearch locale:nil];
    // Bracketed noise first, then the same words bare.
    NSString *noise = @"official( music)?( video| audio| visualizer| lyric video| clip)?|free (dl|download)|out now|premiere|"
                      @"hq|hd|4k|lyrics?|explicit|clean|audio|video|visualizer|download|buy|click buy";
    t = replacing(t, [NSString stringWithFormat:@"[\\(\\[\\{]\\s*(%@)[^\\)\\]\\}]*[\\)\\]\\}]", noise], @" ");
    t = replacing(t, @"[\\(\\[\\{]\\s*prod\\.?( by)?[^\\)\\]\\}]*[\\)\\]\\}]", @" ");
    t = replacing(t, @"\\bprod\\.?( by)?\\s.*$", @" ");
    t = replacing(t, @"\\b(official( music)? (video|audio)|free (dl|download)|out now)\\b", @" ");
    for (NSString *nick in @[artist ?: @"", username ?: @""]) {
        NSString *n = [withoutEmoji(nick).lowercaseString stringByFoldingWithOptions:NSDiacriticInsensitiveSearch locale:nil];
        n = [n stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
        if (n.length < 2) continue;
        t = replacing(t, [NSString stringWithFormat:@"(^|\\s)%@\\s*[-–—:|]\\s*", escaped(n)], @" ");
        t = replacing(t, [NSString stringWithFormat:@"\\b(by|ft\\.?|feat\\.?)?\\s*%@\\b", escaped(n)], @" ");
    }
    // Featured artists differ between uploads of one song.
    t = replacing(t, @"[\\(\\[]\\s*(ft|feat|featuring)\\.?\\s[^\\)\\]]*[\\)\\]]", @" ");
    t = replacing(t, @"\\b(ft|feat|featuring)\\.?\\s.*$", @" ");
    t = replacing(t, @"[^\\p{L}\\p{N}]+", @" ");
    return squeezed(t);
}

NSString *SCVariantTags(NSString *title) {
    NSString *t = [title ?: @"" lowercaseString];
    NSMutableSet *tags = [NSMutableSet set];
    NSDictionary *patterns = @{
        @"remix": @"\\b(re-?mix|rmx)\\b", @"mashup": @"\\bmash-?up\\b", @"edit": @"\\bedit\\b", @"bootleg": @"\\bbootleg\\b",
        @"flip": @"\\bflip\\b", @"vip": @"\\bvip\\b", @"spedup": @"\\b(sped|speed)\\s*-?\\s*up\\b|\\bnightcore\\b",
        @"slowed": @"\\bslowed\\b",
    };
    for (NSString *tag in patterns) {
        NSRegularExpression *re = [NSRegularExpression regularExpressionWithPattern:patterns[tag] options:0 error:nil];
        if ([re firstMatchInString:t options:0 range:NSMakeRange(0, t.length)]) [tags addObject:tag];
    }
    return [[tags.allObjects sortedArrayUsingSelector:@selector(compare:)] componentsJoinedByString:@"+"];
}

double SCTitleSimilarity(NSString *a, NSString *b) {
    NSUInteger la = a.length, lb = b.length;
    if (!la && !lb) return 1;
    if (!la || !lb) return 0;
    if ([a isEqualToString:b]) return 1;
    unichar *ca = malloc(la * sizeof(unichar)), *cb = malloc(lb * sizeof(unichar));
    [a getCharacters:ca range:NSMakeRange(0, la)];
    [b getCharacters:cb range:NSMakeRange(0, lb)];
    NSInteger window = MAX(0, (NSInteger)MAX(la, lb) / 2 - 1);
    BOOL *ma = calloc(la, sizeof(BOOL)), *mb = calloc(lb, sizeof(BOOL));
    double matches = 0;
    for (NSUInteger i = 0; i < la; i++) {
        NSUInteger lo = (NSInteger)i - window > 0 ? i - window : 0, hi = MIN(lb, i + window + 1);
        for (NSUInteger j = lo; j < hi; j++) {
            if (mb[j] || ca[i] != cb[j]) continue;
            ma[i] = mb[j] = YES;
            matches++;
            break;
        }
    }
    double result = 0;
    if (matches > 0) {
        double transpositions = 0;
        NSUInteger k = 0;
        for (NSUInteger i = 0; i < la; i++) {
            if (!ma[i]) continue;
            while (!mb[k]) k++;
            if (ca[i] != cb[k]) transpositions++;
            k++;
        }
        double jaro = (matches / la + matches / lb + (matches - transpositions / 2) / matches) / 3;
        NSUInteger prefix = 0;
        while (prefix < MIN(4, MIN(la, lb)) && ca[prefix] == cb[prefix]) prefix++;
        result = jaro + prefix * 0.1 * (1 - jaro);
    }
    free(ca); free(cb); free(ma); free(mb);
    return result;
}

static NSString *normalizedOf(SCTrack *t) { return SCNormalizedTitle(t.displayTitle, t.displayArtist, t.username); }

BOOL SCTracksAreDuplicates(SCTrack *a, SCTrack *b) {
    if (fabs(a.duration - b.duration) > 3) return NO;
    if (![SCVariantTags(a.title) isEqualToString:SCVariantTags(b.title)]) return NO;
    NSString *na = normalizedOf(a), *nb = normalizedOf(b);
    if (!na.length || !nb.length) return NO;
    return SCTitleSimilarity(na, nb) >= 0.88;
}

static NSString *nickKey(NSString *name) {
    return [SCNormalizedTitle(name ?: @"", nil, nil) stringByReplacingOccurrencesOfString:@" " withString:@""];
}

NSArray<SCTrack *> *SCDeduplicate(NSArray<SCTrack *> *tracks) {
    NSMutableArray<NSMutableArray<SCTrack *> *> *groups = [NSMutableArray array];
    for (SCTrack *track in tracks) {
        NSMutableArray *home = nil;
        for (NSMutableArray<SCTrack *> *group in groups) {
            if (SCTracksAreDuplicates(group.firstObject, track)) {
                home = group;
                break;
            }
        }
        if (home) [home addObject:track];
        else [groups addObject:[NSMutableArray arrayWithObject:track]];
    }
    NSMutableArray *kept = [NSMutableArray arrayWithCapacity:groups.count];
    for (NSArray<SCTrack *> *group in groups) {
        SCTrack *byArtist = nil, *mostPlayed = nil;
        for (SCTrack *t in group) {
            NSString *uploader = nickKey(t.username);
            BOOL own = uploader.length && [uploader isEqualToString:nickKey(t.displayArtist)];
            // Prefer the artist's own upload; among several, the most played.
            if (own && (!byArtist || t.playbackCount > byArtist.playbackCount)) byArtist = t;
            if (!mostPlayed || t.playbackCount > mostPlayed.playbackCount) mostPlayed = t;
        }
        [kept addObject:byArtist ?: mostPlayed];
    }
    return kept;
}
