#import "SCEsperanto.h"
#import "../Core/SCLog.h"
#import "../Core/SCProto.h"
#import <objc/message.h>

static NSString *const kLocalFiles = @"spotify.local_files_esperanto.proto.LocalFiles";
static __weak id gTransport;
static id gStrongTransport;

void SCEsperantoSetCosmosTransport(id transport) {
    if (!transport || gStrongTransport) return;
    gStrongTransport = transport;
    gTransport = transport;
    SCLog(@"esperanto", @"cosmos transport captured (%@)", NSStringFromClass([transport class]));
}

BOOL SCEsperantoReady(void) { return gStrongTransport != nil; }

void SCEsperantoCall(NSString *service, NSString *method, NSData *payload, NSTimeInterval timeout, void (^completion)(NSData *)) {
    id transport = gStrongTransport;
    SEL single = @selector(callSingle:method:payload:onResponse:);
    if (!transport || ![transport respondsToSelector:single]) {
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{ completion(nil); });
        return;
    }
    __block BOOL done = NO;
    NSLock *lock = [NSLock new];
    void (^finish)(NSData *) = ^(NSData *data) {
        [lock lock];
        BOOL first = !done;
        done = YES;
        [lock unlock];
        if (first) dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{ completion(data); });
    };
    void (^onResponse)(NSData *) = ^(NSData *data) { finish([data isKindOfClass:NSData.class] ? data : nil); };
    @try {
        ((id (*)(id, SEL, id, id, id, id))objc_msgSend)(transport, single, service, method, payload ?: [NSData data], onResponse);
    } @catch (NSException *e) {
        SCLog(@"esperanto", @"%@/%@ threw %@", service, method, e.reason);
        finish(nil);
    }
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(timeout * NSEC_PER_SEC)), dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{ finish(nil); });
}

void SCLocalFilesEnableDocuments(void) {
    // DefaultSource { id = IOS_DOCUMENTS (6), enabled = true }
    NSMutableData *source = [NSMutableData data];
    SCProtoAppendVarintField(source, 1, 6);
    SCProtoAppendVarintField(source, 2, 1);
    SCEsperantoCall(kLocalFiles, @"MutateDefaultSource", source, 10, ^(NSData *response) {
        SCLog(@"localfiles", @"documents source: %@", response ? [response description] : @"no answer");
    });
}

static NSString *decodedPart(NSString *part) {
    return [[part stringByReplacingOccurrencesOfString:@"+" withString:@" "] stringByRemovingPercentEncoding] ?: part;
}

static void findOnce(NSString *title, NSString *artist, NSDate *deadline, NSInteger attempt, void (^completion)(NSString *)) {
    // GetTracksRequest { query = Query { text_filter = title } }
    NSMutableData *query = [NSMutableData data], *request = [NSMutableData data];
    SCProtoAppendStringField(query, 1, title);
    SCProtoAppendBytesField(request, 1, query);
    if (attempt % 4 == 0) SCEsperantoCall(kLocalFiles, @"NotifyDefaultSources", [NSData data], 5, ^(NSData *r) {});
    SCEsperantoCall(kLocalFiles, @"GetTracks", request, 8, ^(NSData *response) {
        for (NSString *uri in response ? SCProtoStringsWithPrefix(response, @"spotify:local:") : @[]) {
            NSArray *parts = [[uri substringFromIndex:14] componentsSeparatedByString:@":"];
            if (parts.count >= 3 && [decodedPart(parts[2]) isEqualToString:title]) {
                completion(uri);
                return;
            }
        }
        if ([deadline timeIntervalSinceNow] <= 0) {
            SCLog(@"localfiles", @"\"%@\" is not in Spotify's local files yet", title);
            completion(nil);
            return;
        }
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 700 * NSEC_PER_MSEC), dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
            findOnce(title, artist, deadline, attempt + 1, completion);
        });
    });
}

void SCLocalFilesFindURI(NSString *title, NSString *artist, NSTimeInterval timeout, void (^completion)(NSString *)) {
    findOnce(title, artist, [NSDate dateWithTimeIntervalSinceNow:timeout], 0, completion);
}
