#import "SCLibrary.h"
#import "../Core/SCLog.h"

NSString *const SCAlbumName = @"SoundCloud";
NSString *const SCCacheLimitKey = @"spotcloud.cache.limitMB";

static NSString *formEncoded(NSString *s) {
    static NSCharacterSet *allowed;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        allowed = [NSCharacterSet characterSetWithCharactersInString:
                   @"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_.*"];
    });
    NSMutableString *out = [NSMutableString string];
    NSData *utf8 = [s dataUsingEncoding:NSUTF8StringEncoding];
    const uint8_t *b = utf8.bytes;
    for (NSUInteger i = 0; i < utf8.length; i++) {
        if (b[i] == ' ') [out appendString:@"+"];
        else if (b[i] < 0x80 && [allowed characterIsMember:b[i]]) [out appendFormat:@"%c", b[i]];
        else [out appendFormat:@"%%%02X", b[i]];
    }
    return out;
}

NSString *SCLocalURI(NSString *artist, NSString *album, NSString *title, NSInteger seconds) {
    return [NSString stringWithFormat:@"spotify:local:%@:%@:%@:%ld", formEncoded(artist), formEncoded(album), formEncoded(title), (long)seconds];
}

@implementation SCEntry
- (NSDictionary *)json {
    NSMutableDictionary *d = [@{@"id": @(self.trackID), @"title": self.title, @"artist": self.artist, @"seconds": @(self.seconds),
                                @"uri": self.uri, @"size": @(self.size), @"lastUsed": @(self.lastUsed)} mutableCopy];
    if (self.artworkURL) d[@"artwork"] = self.artworkURL;
    if (self.indexedURI) d[@"indexedURI"] = self.indexedURI;
    if (self.file) d[@"file"] = self.file;
    return d;
}
+ (instancetype)entryWithJSON:(NSDictionary *)d {
    if (![d isKindOfClass:NSDictionary.class] || !d[@"id"] || !d[@"uri"]) return nil;
    SCEntry *e = [self new];
    e.trackID = [d[@"id"] longLongValue];
    e.title = d[@"title"] ?: @"";
    e.artist = d[@"artist"] ?: @"";
    e.seconds = [d[@"seconds"] integerValue];
    e.uri = d[@"uri"];
    e.artworkURL = d[@"artwork"];
    e.indexedURI = d[@"indexedURI"];
    e.file = d[@"file"];
    e.size = [d[@"size"] unsignedLongLongValue];
    e.lastUsed = [d[@"lastUsed"] doubleValue];
    return e;
}
@end

@implementation SCLibrary {
    NSLock *_lock;
    NSMutableDictionary<NSNumber *, SCEntry *> *_byID;
    NSMutableDictionary<NSString *, SCEntry *> *_byURI;
    NSString *_catalogPath;
    BOOL _saveScheduled;
}

+ (instancetype)shared {
    static SCLibrary *library;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ library = [self new]; });
    return library;
}

- (instancetype)init {
    if ((self = [super init])) {
        _lock = [NSLock new];
        _byID = [NSMutableDictionary dictionary];
        _byURI = [NSMutableDictionary dictionary];
        NSString *support = [NSSearchPathForDirectoriesInDomains(NSApplicationSupportDirectory, NSUserDomainMask, YES).firstObject
                             stringByAppendingPathComponent:@"SpotCloud"];
        [NSFileManager.defaultManager createDirectoryAtPath:support withIntermediateDirectories:YES attributes:nil error:nil];
        _catalogPath = [support stringByAppendingPathComponent:@"catalog.json"];
        NSString *documents = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
        _tracksDirectory = [documents stringByAppendingPathComponent:@"SoundCloud"];
        [NSFileManager.defaultManager createDirectoryAtPath:_tracksDirectory withIntermediateDirectories:YES attributes:nil error:nil];
        NSData *data = [NSData dataWithContentsOfFile:_catalogPath];
        NSArray *list = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
        for (id item in [list isKindOfClass:NSArray.class] ? list : @[]) {
            SCEntry *e = [SCEntry entryWithJSON:item];
            if (!e) continue;
            _byID[@(e.trackID)] = e;
            _byURI[e.uri] = e;
            if (e.indexedURI) _byURI[e.indexedURI] = e;
        }
        // Files a stream left unfinished (the app was closed mid-download) are not in the catalog: removed,
        // so Spotify does not list half a track.
        NSMutableSet *known = [NSMutableSet set];
        for (SCEntry *e in _byID.allValues) if (e.file) [known addObject:e.file];
        for (NSString *name in [NSFileManager.defaultManager contentsOfDirectoryAtPath:_tracksDirectory error:nil]) {
            if ([known containsObject:name] || [name hasPrefix:@"."]) continue;
            [NSFileManager.defaultManager removeItemAtPath:[_tracksDirectory stringByAppendingPathComponent:name] error:nil];
            SCLog(@"cache", @"removed unfinished %@", name);
        }
    }
    return self;
}

- (void)scheduleSave {
    if (_saveScheduled) return;
    _saveScheduled = YES;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC), dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        [self->_lock lock];
        self->_saveScheduled = NO;
        // Entries never saved and not used for a week are forgotten.
        NSTimeInterval cutoff = NSDate.date.timeIntervalSince1970 - 7 * 86400;
        NSMutableArray *list = [NSMutableArray array];
        for (SCEntry *e in self->_byID.allValues) {
            if (!e.file && e.lastUsed < cutoff) continue;
            [list addObject:[e json]];
        }
        [self->_lock unlock];
        NSData *data = [NSJSONSerialization dataWithJSONObject:list options:0 error:nil];
        [data writeToFile:self->_catalogPath atomically:YES];
    });
}

- (SCEntry *)registerTrack:(SCTrack *)track {
    [_lock lock];
    SCEntry *e = _byID[@(track.trackID)];
    if (!e) {
        e = [SCEntry new];
        e.trackID = track.trackID;
        e.title = track.markedTitle;
        e.artist = track.displayArtist;
        // Spotify writes the file's whole seconds into a local URI (113.9 s -> 113).
        e.seconds = (NSInteger)floor(track.duration);
        e.uri = SCLocalURI(e.artist, SCAlbumName, e.title, e.seconds);
        _byID[@(e.trackID)] = e;
        _byURI[e.uri] = e;
    }
    e.artworkURL = track.artworkURL ?: e.artworkURL;
    e.lastUsed = MAX(e.lastUsed, NSDate.date.timeIntervalSince1970 - 6 * 86400);
    [_lock unlock];
    [self scheduleSave];
    return e;
}

- (SCEntry *)entryForURI:(NSString *)uri {
    [_lock lock];
    SCEntry *e = _byURI[uri];
    [_lock unlock];
    return e;
}

- (SCEntry *)entryForID:(long long)trackID {
    [_lock lock];
    SCEntry *e = _byID[@(trackID)];
    [_lock unlock];
    return e;
}

- (NSString *)pathForEntry:(SCEntry *)entry {
    if (!entry.file) return nil;
    NSString *path = [_tracksDirectory stringByAppendingPathComponent:entry.file];
    return [NSFileManager.defaultManager fileExistsAtPath:path] ? path : nil;
}

- (void)entry:(SCEntry *)entry savedAs:(NSString *)fileName size:(unsigned long long)size {
    [_lock lock];
    entry.file = fileName;
    entry.size = size;
    entry.lastUsed = NSDate.date.timeIntervalSince1970;
    [_lock unlock];
    [self scheduleSave];
}

- (void)entry:(SCEntry *)entry indexedAs:(NSString *)uri {
    [_lock lock];
    entry.indexedURI = uri;
    _byURI[uri] = entry;
    [_lock unlock];
    [self scheduleSave];
}

- (void)touch:(SCEntry *)entry {
    [_lock lock];
    entry.lastUsed = NSDate.date.timeIntervalSince1970;
    [_lock unlock];
    [self scheduleSave];
}

- (unsigned long long)cachedBytes {
    unsigned long long total = 0;
    [_lock lock];
    for (SCEntry *e in _byID.allValues) if (e.file) total += e.size;
    [_lock unlock];
    return total;
}

- (void)evictKeeping:(NSSet<NSNumber *> *)keep {
    NSInteger limitMB = [NSUserDefaults.standardUserDefaults integerForKey:SCCacheLimitKey];
    unsigned long long limit = (unsigned long long)(limitMB > 0 ? limitMB : 1024) * 1024 * 1024;
    [_lock lock];
    NSArray<SCEntry *> *saved = [[_byID.allValues filteredArrayUsingPredicate:[NSPredicate predicateWithFormat:@"file != nil"]]
                                 sortedArrayUsingDescriptors:@[[NSSortDescriptor sortDescriptorWithKey:@"lastUsed" ascending:YES]]];
    unsigned long long total = 0;
    for (SCEntry *e in saved) total += e.size;
    for (SCEntry *e in saved) {
        if (total <= limit) break;
        if ([keep containsObject:@(e.trackID)]) continue;
        [NSFileManager.defaultManager removeItemAtPath:[_tracksDirectory stringByAppendingPathComponent:e.file] error:nil];
        SCLog(@"cache", @"evicted %@ (%llu MB)", e.file, e.size / 1048576);
        total -= e.size;
        e.file = nil;
        e.size = 0;
    }
    [_lock unlock];
    [self scheduleSave];
}

- (void)removeAllFiles {
    [_lock lock];
    for (SCEntry *e in _byID.allValues) {
        if (e.file) [NSFileManager.defaultManager removeItemAtPath:[_tracksDirectory stringByAppendingPathComponent:e.file] error:nil];
        e.file = nil;
        e.size = 0;
    }
    [_lock unlock];
    [self scheduleSave];
}

@end
