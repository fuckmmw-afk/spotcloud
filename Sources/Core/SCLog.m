#import "SCLog.h"
#import <os/log.h>

NSString *SCSupportDirectory(void) {
    static NSString *path;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSString *documents = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
        path = [documents stringByAppendingPathComponent:@"SpotCloud"];
        [NSFileManager.defaultManager createDirectoryAtPath:path withIntermediateDirectories:YES attributes:nil error:nil];
    });
    return path;
}

void SCLog(NSString *area, NSString *format, ...) {
    va_list args;
    va_start(args, format);
    NSString *message = [[NSString alloc] initWithFormat:format arguments:args];
    va_end(args);
    static os_log_t log;
    static dispatch_queue_t queue;
    static NSDateFormatter *stamp;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        log = os_log_create("spotcloud", "tweak");
        queue = dispatch_queue_create("spotcloud.log", DISPATCH_QUEUE_SERIAL);
        stamp = [NSDateFormatter new];
        stamp.dateFormat = @"HH:mm:ss.SSS";
    });
    os_log(log, "[spotcloud] %{public}@: %{public}@", area, message);
    NSDate *now = [NSDate date];
    dispatch_async(queue, ^{
        NSString *path = [SCSupportDirectory() stringByAppendingPathComponent:@"spotcloud.log"];
        NSFileManager *files = NSFileManager.defaultManager;
        if ([[files attributesOfItemAtPath:path error:nil] fileSize] > 2 * 1024 * 1024) {
            NSString *old = [path stringByAppendingString:@".1"];
            [files removeItemAtPath:old error:nil];
            [files moveItemAtPath:path toPath:old error:nil];
        }
        if (![files fileExistsAtPath:path]) [files createFileAtPath:path contents:nil attributes:nil];
        NSFileHandle *handle = [NSFileHandle fileHandleForWritingAtPath:path];
        [handle seekToEndOfFile];
        NSString *line = [NSString stringWithFormat:@"%@ %@: %@\n", [stamp stringFromDate:now], area, message];
        [handle writeData:[line dataUsingEncoding:NSUTF8StringEncoding]];
        [handle closeFile];
    });
}
