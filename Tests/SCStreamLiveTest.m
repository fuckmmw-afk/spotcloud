// Live test on macOS (CI): streams a real SoundCloud track through SCStream and checks the file.
//  - when it is announced playable, ExtAudioFile opens it and reports the whole track's length;
//  - when complete, afinfo reads it and afconvert decodes all of it.
#import <AudioToolbox/AudioToolbox.h>
#import <Foundation/Foundation.h>
#import "SCClient.h"
#import "SCDedup.h"
#import "SCFilter.h"
#import "SCLibrary.h"
#import "SCStream.h"

static int failures = 0;
#define CHECK(cond) do { if (!(cond)) { failures++; fprintf(stderr, "FAIL %s:%d %s\n", __FILE__, __LINE__, #cond); } } while (0)

int main(void) {
    @autoreleasepool {
        dispatch_semaphore_t done = dispatch_semaphore_create(0);
        __block NSArray<SCTrack *> *found = nil;
        [SCClient.shared searchTracks:@"bootleg remix" limit:30 completion:^(NSArray<SCTrack *> *tracks, NSError *error) {
            NSMutableArray *ok = [NSMutableArray array];
            for (SCTrack *t in tracks) {
                SCTranscoding *best = SCBestTranscoding(t);
                if (SCTrackIsPlayable(t) && best.isAAC && [best.protocol isEqualToString:@"hls"] && t.duration < 400) [ok addObject:t];
            }
            found = ok;
            if (error) fprintf(stderr, "search error: %s\n", error.localizedDescription.UTF8String);
            dispatch_semaphore_signal(done);
        }];
        dispatch_semaphore_wait(done, dispatch_time(DISPATCH_TIME_NOW, 60 * NSEC_PER_SEC));
        CHECK(found.count > 0);
        if (!found.count) return 1;
        SCTrack *track = found.firstObject;
        printf("track %lld \"%s\" by %s, %.1f s\n", track.trackID, track.title.UTF8String, track.displayArtist.UTF8String, track.duration);
        SCEntry *entry = [SCLibrary.shared registerTrack:track];

        __block NSString *playablePath = nil;
        NSDate *started = [NSDate date];
        [SCStream.shared startEntry:entry playable:^(NSString *path, NSError *error) {
            playablePath = path;
            if (error) fprintf(stderr, "stream error: %s\n", error.localizedDescription.UTF8String);
            dispatch_semaphore_signal(done);
        }];
        dispatch_semaphore_wait(done, dispatch_time(DISPATCH_TIME_NOW, 90 * NSEC_PER_SEC));
        CHECK(playablePath != nil);
        if (!playablePath) return 1;
        printf("playable after %.2f s: %s\n", -[started timeIntervalSinceNow], playablePath.lastPathComponent.UTF8String);

        ExtAudioFileRef file = NULL;
        OSStatus status = ExtAudioFileOpenURL((__bridge CFURLRef)[NSURL fileURLWithPath:playablePath], &file);
        CHECK(status == noErr);
        if (status == noErr) {
            SInt64 frames = 0;
            AudioStreamBasicDescription format = {0};
            UInt32 size = sizeof frames;
            ExtAudioFileGetProperty(file, kExtAudioFileProperty_FileLengthFrames, &size, &frames);
            size = sizeof format;
            ExtAudioFileGetProperty(file, kExtAudioFileProperty_FileDataFormat, &size, &format);
            double seconds = format.mSampleRate > 0 ? frames / format.mSampleRate : 0;
            printf("while streaming: %lld frames at %.0f Hz = %.2f s (SoundCloud says %.2f s)\n", frames, format.mSampleRate, seconds, track.duration);
            CHECK(fabs(seconds - track.duration) < 2.5);
            ExtAudioFileDispose(file);
        }

        // Wait for the whole file.
        for (int i = 0; i < 240 && ![SCLibrary.shared pathForEntry:entry]; i++) [NSThread sleepForTimeInterval:0.5];
        NSString *path = [SCLibrary.shared pathForEntry:entry];
        CHECK(path != nil);
        if (!path) return 1;
        printf("complete after %.2f s, %llu bytes\n", -[started timeIntervalSinceNow],
               [[NSFileManager.defaultManager attributesOfItemAtPath:path error:nil] fileSize]);
        NSTask *info = [NSTask launchedTaskWithLaunchPath:@"/usr/bin/afinfo" arguments:@[path]];
        [info waitUntilExit];
        CHECK(info.terminationStatus == 0);
        NSString *wav = [NSTemporaryDirectory() stringByAppendingPathComponent:@"decoded.wav"];
        NSTask *convert = [NSTask launchedTaskWithLaunchPath:@"/usr/bin/afconvert" arguments:@[@"-f", @"WAVE", @"-d", @"LEI16", path, wav]];
        [convert waitUntilExit];
        CHECK(convert.terminationStatus == 0);
        ExtAudioFileRef decoded = NULL;
        if (ExtAudioFileOpenURL((__bridge CFURLRef)[NSURL fileURLWithPath:wav], &decoded) == noErr) {
            SInt64 frames = 0;
            AudioStreamBasicDescription format = {0};
            UInt32 size = sizeof frames;
            ExtAudioFileGetProperty(decoded, kExtAudioFileProperty_FileLengthFrames, &size, &frames);
            size = sizeof format;
            ExtAudioFileGetProperty(decoded, kExtAudioFileProperty_FileDataFormat, &size, &format);
            double seconds = frames / format.mSampleRate;
            printf("decoded: %.2f s\n", seconds);
            CHECK(fabs(seconds - track.duration) < 2.5);
            // Not silence: some samples well above zero in the middle.
            ExtAudioFileSeek(decoded, frames / 2);
            int16_t buffer[4096 * 2];
            AudioBufferList list = {.mNumberBuffers = 1, .mBuffers = {{.mNumberChannels = format.mChannelsPerFrame, .mDataByteSize = sizeof buffer, .mData = buffer}}};
            UInt32 n = 4096;
            ExtAudioFileRead(decoded, &n, &list);
            int peak = 0;
            for (UInt32 i = 0; i < n * format.mChannelsPerFrame; i++) peak = MAX(peak, abs(buffer[i]));
            printf("peak in the middle: %d\n", peak);
            CHECK(peak > 100);
            ExtAudioFileDispose(decoded);
        } else {
            CHECK(!"decoded wav did not open");
        }
        NSTask *tags = [NSTask launchedTaskWithLaunchPath:@"/usr/bin/mdls" arguments:@[@"-name", @"kMDItemTitle", @"-name", @"kMDItemAlbum", path]];
        [tags waitUntilExit];
    }
    if (failures) { fprintf(stderr, "%d failed\n", failures); return 1; }
    puts("stream live test passed");
    return 0;
}
