// Stage 0, second pass: what a tap on a track sends to the player, what the queue looks like, and the
// local files switch. Logs to Documents/SpotCloud/probe-player.txt; changes nothing.
#import <Foundation/Foundation.h>
#import <objc/message.h>
#import <objc/runtime.h>
#import "../Core/SCFeatures.h"
#import "../Core/SCLog.h"
#import "../Core/SCSwizzle.h"

static dispatch_queue_t gQueue;

static NSString *clip(id value, NSUInteger max) {
    NSString *s = value ? [NSString stringWithFormat:@"<%@> %@", NSStringFromClass([value class]), value] : @"nil";
    return s.length > max ? [[s substringToIndex:max] stringByAppendingString:@"…"] : s;
}

static void note(NSString *line) {
    NSString *stamped = [NSString stringWithFormat:@"%@ %@\n\n", [NSDate date], line];
    dispatch_async(gQueue, ^{
        NSString *path = [SCSupportDirectory() stringByAppendingPathComponent:@"probe-player.txt"];
        NSFileManager *files = NSFileManager.defaultManager;
        if (![files fileExistsAtPath:path]) [files createFileAtPath:path contents:nil attributes:nil];
        if ([[files attributesOfItemAtPath:path error:nil] fileSize] > 6 * 1024 * 1024) return;
        NSFileHandle *handle = [NSFileHandle fileHandleForWritingAtPath:path];
        [handle seekToEndOfFile];
        [handle writeData:[stamped dataUsingEncoding:NSUTF8StringEncoding]];
        [handle closeFile];
    });
}

static id safeKey(id object, NSString *key) {
    @try { return [object valueForKey:key]; } @catch (NSException *e) { return nil; }
}

typedef id (*Obj2)(id, SEL, id, id);
typedef id (*Obj3)(id, SEL, id, id, id);
typedef id (*Obj4)(id, SEL, id, id, id, id);
typedef void (*Void2)(id, SEL, id, id);
static Obj2 gPlay2;
static Obj3 gPlayAsNext, gAdd3;
static Obj4 gExecute;
static Void2 gStateUpdate;

static id execute(id self, SEL _cmd, id command, id options, id logging, id origin) {
    SCGuard(SCFeatureProbe, @"execute", ^{
        NSMutableString *line = [NSMutableString stringWithFormat:@"executePlayCommand %@\n options %@\n origin %@",
                                 clip(command, 6000), clip(options, 1500), clip(origin, 800)];
        for (NSString *key in @[@"context", @"uri", @"URI", @"contextURI", @"pages", @"metadata", @"playOrigin"]) {
            id v = safeKey(command, key);
            if (v) [line appendFormat:@"\n command.%@ = %@", key, clip(v, 3000)];
        }
        note(line);
    });
    return gExecute(self, _cmd, command, options, logging, origin);
}

static id playContext(id self, SEL _cmd, id context, id options) {
    SCGuard(SCFeatureProbe, @"playContext", ^{
        NSMutableString *line = [NSMutableString stringWithFormat:@"playContext %@\n options %@", clip(context, 6000), clip(options, 1500)];
        for (NSString *key in @[@"uri", @"URI", @"url", @"pages", @"metadata", @"tracks"]) {
            id v = safeKey(context, key);
            if (v) [line appendFormat:@"\n context.%@ = %@", key, clip(v, 3000)];
        }
        note(line);
    });
    return gPlay2(self, _cmd, context, options);
}

static id addToQueue(id self, SEL _cmd, id what, id options, id logging) {
    SCGuard(SCFeatureProbe, @"addToQueue", ^{ note([NSString stringWithFormat:@"addToQueue %@ options %@", clip(what, 3000), clip(options, 800)]); });
    return gAdd3(self, _cmd, what, options, logging);
}

static id playAsNext(id self, SEL _cmd, id what, id options, id logging) {
    SCGuard(SCFeatureProbe, @"playAsNext", ^{ note([NSString stringWithFormat:@"playAsNextInQueue %@ options %@", clip(what, 3000), clip(options, 800)]); });
    return gPlayAsNext(self, _cmd, what, options, logging);
}

static NSString *gLastTrack;
static void stateUpdate(id self, SEL _cmd, id subscription, id state) {
    SCGuard(SCFeatureProbe, @"state", ^{
        id track = safeKey(state, @"track");
        NSString *uri = [safeKey(track, @"URI") description] ?: [safeKey(track, @"uri") description];
        if (uri && [uri isEqualToString:gLastTrack]) return;
        gLastTrack = uri;
        NSArray *next = safeKey(state, @"nextTracks");
        NSMutableString *line = [NSMutableString stringWithFormat:@"state: track %@\n track object %@\n state object %@", uri,
                                 clip(track, 2500), clip(state, 2500)];
        NSUInteger i = 0;
        for (id t in [next isKindOfClass:NSArray.class] ? next : @[]) {
            if (i++ >= 5) break;
            [line appendFormat:@"\n next %lu: %@", (unsigned long)i, clip(t, 800)];
        }
        note(line);
    });
    gStateUpdate(self, _cmd, subscription, state);
}

typedef id (*Obj0)(id, SEL);
static Obj0 gProvideModel;
static id provideModel(id self, SEL _cmd) {
    id model = gProvideModel(self, _cmd);
    SCGuard(SCFeatureProbe, @"local files model", ^{
        BOOL enabled = [model respondsToSelector:@selector(enabled)] ? ((BOOL (*)(id, SEL))objc_msgSend)(model, @selector(enabled)) : NO;
        long status = [model respondsToSelector:NSSelectorFromString(@"permissionStatus")]
            ? ((long (*)(id, SEL))objc_msgSend)(model, NSSelectorFromString(@"permissionStatus")) : -99;
        note([NSString stringWithFormat:@"local files model %@ enabled %d permissionStatus %ld", clip(model, 300), enabled, status]);
    });
    return model;
}

static void copyLocalFilesState(void) {
    NSFileManager *files = NSFileManager.defaultManager;
    NSString *users = [NSHomeDirectory() stringByAppendingPathComponent:@"Library/Application Support/Users"];
    NSString *out = [SCSupportDirectory() stringByAppendingPathComponent:@"localfiles-state"];
    [files createDirectoryAtPath:out withIntermediateDirectories:YES attributes:nil error:nil];
    for (NSString *user in [files contentsOfDirectoryAtPath:users error:nil]) {
        for (NSString *name in @[@"local-files.bnk", @"local_sync_state"]) {
            NSString *src = [[users stringByAppendingPathComponent:user] stringByAppendingPathComponent:name];
            BOOL directory = NO;
            if (![files fileExistsAtPath:src isDirectory:&directory]) continue;
            NSString *dst = [out stringByAppendingPathComponent:name];
            [files removeItemAtPath:dst error:nil];
            [files copyItemAtPath:src toPath:dst error:nil];
        }
    }
}

void SCProbePlayerStart(void) {
    gQueue = dispatch_queue_create("spotcloud.probe.player", DISPATCH_QUEUE_SERIAL);
    Class player = objc_getClass("SPTEsperantoPlayer");
    gExecute = (Obj4)SCSwizzle(player, @selector(executePlayCommand:options:loggingParams:origin:), (IMP)execute);
    gPlay2 = (Obj2)SCSwizzle(player, @selector(playContext:options:), (IMP)playContext);
    gAdd3 = (Obj3)SCSwizzle(player, @selector(addToQueue:options:loggingParams:), (IMP)addToQueue);
    gPlayAsNext = (Obj3)SCSwizzle(player, @selector(playAsNextInQueue:options:loggingParams:), (IMP)playAsNext);
    gStateUpdate = (Void2)SCSwizzle(player, @selector(globalPlayerSubscription:gotStateUpdate:), (IMP)stateUpdate);
    gProvideModel = (Obj0)SCSwizzle(objc_getClass("LocalFiles_CoreImpl.LocalFilesAPIService"), @selector(provideLocalFilesSettingsModel), (IMP)provideModel);
    SCLog(@"probe", @"player: execute %d play %d queue %d state %d; local files model %d", gExecute != NULL, gPlay2 != NULL,
          gAdd3 != NULL, gStateUpdate != NULL, gProvideModel != NULL);
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 15 * NSEC_PER_SEC), gQueue, ^{
        SCGuard(SCFeatureProbe, @"local files copy", ^{ copyLocalFilesState(); });
    });
}
