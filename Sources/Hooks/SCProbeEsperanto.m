// Stage 0, second pass: every Esperanto call Swift code makes to the core goes through one Objective-C
// bridge (SPTEsperantoTransportBridgeImpl, and SPTEsperantoCosmosTransport for Cosmos). Logs service,
// method, payload size and the response block's signature; dumps payloads and responses of the services
// SpotCloud needs (search, local files, player, queue). Changes nothing.
#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import "../Core/SCFeatures.h"
#import "../Core/SCLog.h"
#import "../Core/SCSwizzle.h"

struct SCBlockDescriptor { unsigned long reserved, size; void *rest[]; };
struct SCBlockLayout { void *isa; int flags, reserved; void *invoke; struct SCBlockDescriptor *descriptor; };

const char *SCBlockSignature(id block) {
    if (!block) return NULL;
    struct SCBlockLayout *layout = (__bridge void *)block;
    if (!(layout->flags & (1 << 30))) return NULL;
    void **rest = layout->descriptor->rest;
    if (layout->flags & (1 << 25)) rest += 2;  // copy and dispose helpers
    return (const char *)rest[0];
}

static NSString *text(id value) {
    if (!value) return @"nil";
    if ([value isKindOfClass:NSString.class]) return value;
    return [NSString stringWithFormat:@"<%@> %@", NSStringFromClass([value class]), value];
}

static BOOL interesting(NSString *service, NSString *method) {
    NSString *both = [[NSString stringWithFormat:@"%@/%@", service, method] lowercaseString];
    for (NSString *word in @[@"search", @"local", @"player", @"queue", @"play", @"collection", @"metadata"]) {
        if ([both containsString:word]) return YES;
    }
    return NO;
}

static NSLock *gLock;
static NSMutableDictionary<NSString *, NSNumber *> *gSeen;
static NSMutableString *gCalls;

static NSString *dumpsDir(void) {
    NSString *dir = [SCSupportDirectory() stringByAppendingPathComponent:@"esperanto"];
    [NSFileManager.defaultManager createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];
    return dir;
}

static NSString *safeName(NSString *s) {
    NSCharacterSet *bad = [[NSCharacterSet alphanumericCharacterSet] invertedSet];
    return [[s componentsSeparatedByCharactersInSet:bad] componentsJoinedByString:@"_"];
}

static void writeValue(id value, NSString *path) {
    if ([value isKindOfClass:NSData.class]) {
        [(NSData *)value writeToFile:path atomically:YES];
        return;
    }
    NSMutableString *out = [NSMutableString stringWithString:text(value)];
    // Response objects usually carry the payload as NSData in a property; save whichever they have.
    for (NSString *key in @[@"payload", @"data", @"body", @"result", @"status", @"statusCode", @"error"]) {
        @try {
            id inner = [value valueForKey:key];
            if ([inner isKindOfClass:NSData.class]) [(NSData *)inner writeToFile:[path stringByAppendingFormat:@".%@.bin", key] atomically:YES];
            [out appendFormat:@"\n.%@ = %@", key, text(inner)];
        } @catch (NSException *e) {}
    }
    [out writeToFile:[path stringByAppendingString:@".txt"] atomically:YES encoding:NSUTF8StringEncoding error:nil];
}

// Returns the dump stem (service-method-n) when this call should be dumped, else nil.
static NSString *record(NSString *kind, id service, id method, id payload, id block) {
    NSString *s = text(service), *m = text(method);
    const char *signature = SCBlockSignature(block);
    NSUInteger size = [payload isKindOfClass:NSData.class] ? [(NSData *)payload length] : 0;
    NSString *key = [NSString stringWithFormat:@"%@/%@", s, m];
    [gLock lock];
    NSInteger n = gSeen[key].integerValue;
    gSeen[key] = @(n + 1);
    if (n < 3 || n % 50 == 0) {
        [gCalls appendFormat:@"%@ %@ %@ payload %lu block %s (#%ld)\n", kind, s, m, (unsigned long)size, signature ?: "-", (long)n + 1];
    }
    [gLock unlock];
    if (n >= 3 || !interesting(s, m)) return nil;
    NSString *stem = [dumpsDir() stringByAppendingPathComponent:[NSString stringWithFormat:@"%@-%ld", safeName(key), (long)n]];
    writeValue(payload, [stem stringByAppendingString:@".request.bin"]);
    return stem;
}

// A response block that takes one object (signature "v16@?0@8") is wrapped to dump what it is given.
static id wrapResponse(id block, NSString *stem) {
    const char *signature = SCBlockSignature(block);
    if (!stem || !signature || strcmp(signature, "v16@?0@8") != 0) return block;
    void (^original)(id) = block;
    __block NSInteger count = 0;
    return ^(id response) {
        if (count++ < 2) {
            SCGuard(SCFeatureProbe, @"esperanto response", ^{
                writeValue(response, [stem stringByAppendingFormat:@".response%ld", (long)count]);
            });
        }
        original(response);
    };
}

typedef id (*CallBlock)(id, SEL, id, id, id, id);
typedef id (*CallSync)(id, SEL, id, id, id);
static CallBlock gBridgeSingle, gBridgeStream, gCosmosSingle, gCosmosStream;
static CallSync gBridgeSync, gCosmosSync;

#define CALL_HOOK(name, orig, kind) \
static id name(id self, SEL _cmd, id service, id method, id payload, id onResponse) { \
    __block id block = onResponse; \
    SCGuard(SCFeatureProbe, @kind, ^{ block = wrapResponse(onResponse, record(@kind, service, method, payload, onResponse)); }); \
    return orig(self, _cmd, service, method, payload, block); \
}
CALL_HOOK(bridgeSingle, gBridgeSingle, "single")
CALL_HOOK(bridgeStream, gBridgeStream, "stream")
CALL_HOOK(cosmosSingle, gCosmosSingle, "cosmos-single")
CALL_HOOK(cosmosStream, gCosmosStream, "cosmos-stream")

static id bridgeSync(id self, SEL _cmd, id service, id method, id payload) {
    SCGuard(SCFeatureProbe, @"sync", ^{ record(@"sync", service, method, payload, nil); });
    return gBridgeSync(self, _cmd, service, method, payload);
}
static id cosmosSync(id self, SEL _cmd, id service, id method, id payload) {
    SCGuard(SCFeatureProbe, @"cosmos-sync", ^{ record(@"cosmos-sync", service, method, payload, nil); });
    return gCosmosSync(self, _cmd, service, method, payload);
}

static dispatch_source_t gEsperantoTimer;

void SCProbeEsperantoStart(void) {
    gLock = [NSLock new];
    gSeen = [NSMutableDictionary dictionary];
    gCalls = [NSMutableString string];
    Class bridge = objc_getClass("SPTEsperantoTransportBridgeImpl"), cosmos = objc_getClass("SPTEsperantoCosmosTransport");
    SEL single = @selector(callSingle:method:payload:onResponse:), stream = @selector(callStream:method:payload:onResponse:),
        sync = @selector(callSync:method:payload:);
    gBridgeSingle = (CallBlock)SCSwizzle(bridge, single, (IMP)bridgeSingle);
    gBridgeStream = (CallBlock)SCSwizzle(bridge, stream, (IMP)bridgeStream);
    gBridgeSync = (CallSync)SCSwizzle(bridge, sync, (IMP)bridgeSync);
    gCosmosSingle = (CallBlock)SCSwizzle(cosmos, single, (IMP)cosmosSingle);
    gCosmosStream = (CallBlock)SCSwizzle(cosmos, stream, (IMP)cosmosStream);
    gCosmosSync = (CallSync)SCSwizzle(cosmos, sync, (IMP)cosmosSync);
    SCLog(@"probe", @"esperanto bridge %@, cosmos %@", gBridgeSingle ? @"watched" : @"missing", gCosmosSingle ? @"watched" : @"missing");
    dispatch_source_t timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_global_queue(QOS_CLASS_UTILITY, 0));
    dispatch_source_set_timer(timer, dispatch_time(DISPATCH_TIME_NOW, 3 * NSEC_PER_SEC), 3 * NSEC_PER_SEC, NSEC_PER_SEC);
    dispatch_source_set_event_handler(timer, ^{
        [gLock lock];
        NSString *calls = [gCalls copy];
        [gCalls setString:@""];
        [gLock unlock];
        if (!calls.length) return;
        NSString *path = [SCSupportDirectory() stringByAppendingPathComponent:@"probe-esperanto.txt"];
        NSFileManager *files = NSFileManager.defaultManager;
        if (![files fileExistsAtPath:path]) [files createFileAtPath:path contents:nil attributes:nil];
        NSFileHandle *handle = [NSFileHandle fileHandleForWritingAtPath:path];
        [handle seekToEndOfFile];
        [handle writeData:[calls dataUsingEncoding:NSUTF8StringEncoding]];
        [handle closeFile];
    });
    dispatch_resume(timer);
    gEsperantoTimer = timer;
}
