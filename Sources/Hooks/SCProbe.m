// Stage 0: finds where Spotify 9.1.90 keeps search, the player, the queue and local files, without changing
// anything. Writes Documents/SpotCloud/probe-*.txt and dumps a few response bodies to Documents/SpotCloud/dumps.
#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import "../Core/SCFeatures.h"
#import "../Core/SCLog.h"
#import "../Core/SCSwizzle.h"

#pragma mark - classes

static NSArray<NSString *> *probePatterns(void) {
    return @[@"Search", @"LocalFile", @"Player", @"Queue", @"Esperanto", @"NowPlaying", @"TrackRow", @"DataLoader",
             @"HttpClient", @"ContextMenu", @"Playback", @"Hubs", @"Encore"];
}

static void describeClass(Class cls, NSMutableString *out) {
    Class superclass = class_getSuperclass(cls);
    [out appendFormat:@"\n@class %s : %s", class_getName(cls), superclass ? class_getName(superclass) : "-"];
    unsigned count = 0;
    Protocol *__unsafe_unretained *protocols = class_copyProtocolList(cls, &count);
    if (count) {
        [out appendString:@" <"];
        for (unsigned i = 0; i < count; i++) [out appendFormat:@"%s%s", i ? ", " : "", protocol_getName(protocols[i])];
        [out appendString:@">"];
    }
    free(protocols);
    [out appendString:@"\n"];
    for (int meta = 1; meta >= 0; meta--) {
        Class target = meta ? object_getClass(cls) : cls;
        Method *methods = class_copyMethodList(target, &count);
        for (unsigned i = 0; i < count && i < 400; i++) {
            [out appendFormat:@"  %c%s  %s\n", meta ? '+' : '-', sel_getName(method_getName(methods[i])),
                              method_getTypeEncoding(methods[i]) ?: ""];
        }
        free(methods);
    }
    Ivar *ivars = class_copyIvarList(cls, &count);
    for (unsigned i = 0; i < count && i < 100; i++) {
        [out appendFormat:@"  ivar %s %s\n", ivar_getName(ivars[i]) ?: "?", ivar_getTypeEncoding(ivars[i]) ?: ""];
    }
    free(ivars);
}

static void dumpClasses(void) {
    unsigned count = 0;
    Class *classes = objc_copyClassList(&count);
    NSMutableString *out = [NSMutableString stringWithFormat:@"Spotify %@, %u classes\n",
                            NSBundle.mainBundle.infoDictionary[@"CFBundleShortVersionString"], count];
    NSArray *patterns = probePatterns();
    NSUInteger matched = 0;
    for (unsigned i = 0; i < count; i++) {
        const char *raw = class_getName(classes[i]);
        if (!raw || strncmp(raw, "SG", 2) == 0 || strncmp(raw, "NSKVONotifying", 14) == 0) continue;
        NSString *name = @(raw);
        for (NSString *pattern in patterns) {
            if ([name rangeOfString:pattern].location != NSNotFound) {
                describeClass(classes[i], out);
                matched++;
                break;
            }
        }
    }
    free(classes);
    unsigned protocolCount = 0;
    Protocol *__unsafe_unretained *protocols = objc_copyProtocolList(&protocolCount);
    [out appendString:@"\n\n# protocols\n"];
    for (unsigned i = 0; i < protocolCount; i++) {
        NSString *name = @(protocol_getName(protocols[i]));
        BOOL wanted = NO;
        for (NSString *pattern in patterns) wanted = wanted || [name rangeOfString:pattern].location != NSNotFound;
        if (!wanted) continue;
        [out appendFormat:@"\n@protocol %@\n", name];
        for (int required = 1; required >= 0; required--) {
            unsigned n = 0;
            struct objc_method_description *list = protocol_copyMethodDescriptionList(protocols[i], required, YES, &n);
            for (unsigned k = 0; k < n; k++) [out appendFormat:@"  %s- %s %s\n", required ? "" : "?", sel_getName(list[k].name), list[k].types];
            free(list);
        }
    }
    free(protocols);
    NSString *path = [SCSupportDirectory() stringByAppendingPathComponent:@"probe-classes.txt"];
    [out writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:nil];
    SCLog(@"probe", @"%lu classes described in %@", (unsigned long)matched, path.lastPathComponent);
}

static void dumpDefaults(void) {
    NSMutableString *out = [NSMutableString string];
    NSDictionary *all = NSUserDefaults.standardUserDefaults.dictionaryRepresentation;
    for (NSString *key in [all.allKeys sortedArrayUsingSelector:@selector(compare:)]) {
        if (![key hasPrefix:@"spotifyglass.dsp"] && ![key hasPrefix:@"spotcloud."] &&
            [key rangeOfString:@"ocal" options:NSCaseInsensitiveSearch].location == NSNotFound) continue;
        id value = all[key];
        NSString *text = [value description];
        if (text.length > 400) text = [[text substringToIndex:400] stringByAppendingString:@"…"];
        [out appendFormat:@"%@ (%@) = %@\n", key, NSStringFromClass([value class]), text];
    }
    [out writeToFile:[SCSupportDirectory() stringByAppendingPathComponent:@"probe-defaults.txt"] atomically:YES
            encoding:NSUTF8StringEncoding error:nil];
}

static void dumpFiles(void) {
    NSMutableString *out = [NSMutableString string];
    NSFileManager *files = NSFileManager.defaultManager;
    NSString *home = NSHomeDirectory();
    for (NSString *top in @[@"Documents", @"Library/Application Support", @"Library/Caches"]) {
        NSString *root = [home stringByAppendingPathComponent:top];
        NSDirectoryEnumerator *walk = [files enumeratorAtPath:root];
        NSUInteger shown = 0;
        for (NSString *relative in walk) {
            if (walk.level > 3) { [walk skipDescendants]; continue; }
            NSString *lower = relative.lowercaseString;
            BOOL interesting = walk.level <= 2 || [lower containsString:@"local"] || [lower hasSuffix:@".m4a"] || [lower hasSuffix:@".mp3"];
            if (!interesting || ++shown > 600) continue;
            [out appendFormat:@"%@/%@\n", top, relative];
        }
    }
    [out writeToFile:[SCSupportDirectory() stringByAppendingPathComponent:@"probe-files.txt"] atomically:YES
            encoding:NSUTF8StringEncoding error:nil];
}

#pragma mark - network

static NSLock *gLock;
static NSMutableDictionary<NSString *, NSMutableData *> *gBodies;
static NSMutableDictionary<NSString *, NSNumber *> *gDumped;
static NSMutableString *gRequests;

static BOOL wantsBody(NSURL *url) {
    NSString *path = url.path.lowercaseString ?: @"";
    return [path containsString:@"search"] || [path containsString:@"local"] || [path containsString:@"queue"] ||
           [path containsString:@"context-resolve"] || [path containsString:@"track-playback"];
}

static NSString *taskKey(id session, NSURLSessionTask *task) {
    return [NSString stringWithFormat:@"%p-%lu", session, (unsigned long)task.taskIdentifier];
}

static void recordData(id session, NSURLSessionTask *task, NSData *data) {
    NSURL *url = task.currentRequest.URL;
    if (!url || !wantsBody(url) || !data.length) return;
    [gLock lock];
    NSString *key = taskKey(session, task);
    NSMutableData *body = gBodies[key];
    if (!body) gBodies[key] = body = [NSMutableData data];
    if (body.length < 4 * 1024 * 1024) [body appendData:data];
    [gLock unlock];
}

static void recordCompletion(id session, NSURLSessionTask *task, NSError *error) {
    NSURL *url = task.currentRequest.URL;
    if (!url) return;
    NSHTTPURLResponse *response = [task.response isKindOfClass:NSHTTPURLResponse.class] ? (NSHTTPURLResponse *)task.response : nil;
    [gLock lock];
    NSString *key = taskKey(session, task);
    NSData *body = gBodies[key];
    [gBodies removeObjectForKey:key];
    [gRequests appendFormat:@"%@ %@%@ -> %ld %@ %lu bytes%@\n", task.currentRequest.HTTPMethod, url.host, url.path,
                            (long)response.statusCode, response.allHeaderFields[@"Content-Type"] ?: @"",
                            (unsigned long)body.length, error ? [@" error " stringByAppendingString:error.localizedDescription] : @""];
    NSString *dumpName = nil;
    if (body.length) {
        NSString *stem = [[url.path stringByReplacingOccurrencesOfString:@"/" withString:@"_"] substringToIndex:MIN(url.path.length, (NSUInteger)80)];
        NSInteger n = gDumped[stem].integerValue;
        if (n < 4) {
            gDumped[stem] = @(n + 1);
            dumpName = [NSString stringWithFormat:@"%@-%ld.bin", stem, (long)n];
        }
    }
    BOOL flush = gRequests.length > 512;
    NSString *requests = flush ? [gRequests copy] : nil;
    if (flush) [gRequests setString:@""];
    [gLock unlock];

    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        NSString *dir = [SCSupportDirectory() stringByAppendingPathComponent:@"dumps"];
        if (dumpName) {
            [NSFileManager.defaultManager createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];
            [body writeToFile:[dir stringByAppendingPathComponent:dumpName] atomically:YES];
            NSString *meta = [NSString stringWithFormat:@"%@\n%@\n%@\n", url.absoluteString, task.currentRequest.allHTTPHeaderFields,
                              response.allHeaderFields];
            [meta writeToFile:[dir stringByAppendingPathComponent:[dumpName stringByAppendingString:@".txt"]] atomically:YES
                     encoding:NSUTF8StringEncoding error:nil];
        }
        if (requests) {
            NSString *path = [SCSupportDirectory() stringByAppendingPathComponent:@"probe-requests.txt"];
            if (![NSFileManager.defaultManager fileExistsAtPath:path]) [NSFileManager.defaultManager createFileAtPath:path contents:nil attributes:nil];
            NSFileHandle *handle = [NSFileHandle fileHandleForWritingAtPath:path];
            [handle seekToEndOfFile];
            [handle writeData:[requests dataUsingEncoding:NSUTF8StringEncoding]];
            [handle closeFile];
        }
    });
}

typedef void (*DidReceiveData)(id, SEL, NSURLSession *, NSURLSessionDataTask *, NSData *);
typedef void (*DidComplete)(id, SEL, NSURLSession *, NSURLSessionTask *, NSError *);

#define PROBE_SLOTS 4
static Class gProbeClasses[PROBE_SLOTS];
static DidReceiveData gOrigData[PROBE_SLOTS];
static DidComplete gOrigComplete[PROBE_SLOTS];

static int slotFor(id self) {
    for (int i = 0; i < PROBE_SLOTS; i++) {
        if (gProbeClasses[i] && [self isKindOfClass:gProbeClasses[i]]) return i;
    }
    return -1;
}

static void probeDidReceiveData(id self, SEL _cmd, NSURLSession *session, NSURLSessionDataTask *task, NSData *data) {
    SCGuard(SCFeatureProbe, @"didReceiveData", ^{ recordData(session, task, data); });
    int slot = slotFor(self);
    if (slot >= 0 && gOrigData[slot]) gOrigData[slot](self, _cmd, session, task, data);
}

static void probeDidComplete(id self, SEL _cmd, NSURLSession *session, NSURLSessionTask *task, NSError *error) {
    SCGuard(SCFeatureProbe, @"didComplete", ^{ recordCompletion(session, task, error); });
    int slot = slotFor(self);
    if (slot >= 0 && gOrigComplete[slot]) gOrigComplete[slot](self, _cmd, session, task, error);
}

static void hookSessionDelegate(const char *name, int slot) {
    Class cls = objc_getClass(name);
    if (!cls) {
        SCLog(@"probe", @"%s is not in this build", name);
        return;
    }
    gProbeClasses[slot] = cls;
    gOrigData[slot] = (DidReceiveData)SCSwizzle(cls, @selector(URLSession:dataTask:didReceiveData:), (IMP)probeDidReceiveData);
    gOrigComplete[slot] = (DidComplete)SCSwizzle(cls, @selector(URLSession:task:didCompleteWithError:), (IMP)probeDidComplete);
    SCLog(@"probe", @"watching %s (data %@, completion %@)", name, gOrigData[slot] ? @"yes" : @"no", gOrigComplete[slot] ? @"yes" : @"no");
}

void SCProbeStart(void) {
    gLock = [NSLock new];
    gBodies = [NSMutableDictionary dictionary];
    gDumped = [NSMutableDictionary dictionary];
    gRequests = [NSMutableString string];
    hookSessionDelegate("SPTDataLoaderService", 0);
    hookSessionDelegate("HttpClientURLSession", 1);
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 12 * NSEC_PER_SEC), dispatch_get_global_queue(QOS_CLASS_BACKGROUND, 0), ^{
        SCGuard(SCFeatureProbe, @"class dump", ^{ dumpClasses(); });
        SCGuard(SCFeatureProbe, @"defaults dump", ^{ dumpDefaults(); });
        SCGuard(SCFeatureProbe, @"files dump", ^{ dumpFiles(); });
    });
}
