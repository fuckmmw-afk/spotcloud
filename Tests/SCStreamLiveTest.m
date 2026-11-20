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

// RMS of each second of a 16-bit WAV.
static NSArray<NSNumber *> *loudness(NSString *wav) {
    ExtAudioFileRef f = NULL;
    if (ExtAudioFileOpenURL((__bridge CFURLRef)[NSURL fileURLWithPath:wav], &f) != noErr) return @[];
    AudioStreamBasicDescription format = {0};
    UInt32 size = sizeof format;
    ExtAudioFileGetProperty(f, kExtAudioFileProperty_FileDataFormat, &size, &format);
    UInt32 rate = (UInt32)format.mSampleRate, channels = format.mChannelsPerFrame;
    NSMutableArray *out = [NSMutableArray array];
    int16_t *buffer = malloc(rate * channels * 2);
    while (1) {
        AudioBufferList list = {.mNumberBuffers = 1, .mBuffers = {{.mNumberChannels = channels, .mDataByteSize = rate * channels * 2, .mData = buffer}}};
        UInt32 n = rate;
        if (ExtAudioFileRead(f, &n, &list) != noErr || n == 0) break;
        double sum = 0;
        for (UInt32 i = 0; i < n * channels; i++) sum += (double)buffer[i] * buffer[i];
        [out addObject:@(sqrt(sum / (n * channels)))];
    }
    free(buffer);
    ExtAudioFileDispose(f);
    return out;
}

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
        NSArray<NSNumber *> *ours = loudness(wav);

        // Reference: the HLS fMP4 as SoundCloud serves it (init + fragments joined), decoded the same way.
        __block NSURL *playlistURL = nil;
        [SCClient.shared streamURLForTranscoding:SCBestTranscoding(track) track:track completion:^(NSURL *url, NSError *error) {
            playlistURL = url;
            dispatch_semaphore_signal(done);
        }];
        dispatch_semaphore_wait(done, dispatch_time(DISPATCH_TIME_NOW, 30 * NSEC_PER_SEC));
        NSString *text = [NSString stringWithContentsOfURL:playlistURL encoding:NSUTF8StringEncoding error:nil];
        NSMutableData *joined = [NSMutableData data];
        for (NSString *line in [text componentsSeparatedByString:@"\n"]) {
            NSString *l = [line stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
            NSString *uri = nil;
            if ([l hasPrefix:@"#EXT-X-MAP:URI=\""]) uri = [[l substringFromIndex:16] componentsSeparatedByString:@"\""].firstObject;
            else if (l.length && ![l hasPrefix:@"#"]) uri = l;
            if (uri) [joined appendData:[NSData dataWithContentsOfURL:[NSURL URLWithString:uri relativeToURL:playlistURL]]];
        }
        NSString *reference = [NSTemporaryDirectory() stringByAppendingPathComponent:@"reference.mp4"];
        NSString *referenceWav = [NSTemporaryDirectory() stringByAppendingPathComponent:@"reference.wav"];
        [joined writeToFile:reference atomically:YES];
        NSTask *convertRef = [NSTask launchedTaskWithLaunchPath:@"/usr/bin/afconvert" arguments:@[@"-f", @"WAVE", @"-d", @"LEI16", reference, referenceWav]];
        [convertRef waitUntilExit];
        NSArray<NSNumber *> *theirs = convertRef.terminationStatus == 0 ? loudness(referenceWav) : nil;
        printf("seconds: ours %lu, reference %lu\n", (unsigned long)ours.count, (unsigned long)theirs.count);
        CHECK(theirs.count > 0 && labs((long)ours.count - (long)theirs.count) <= 1);
        double worst = 0;
        NSUInteger silent = 0;
        for (NSUInteger i = 0; i < MIN(ours.count, theirs.count); i++) {
            double a = ours[i].doubleValue, b = theirs[i].doubleValue;
            if (a < 30) silent++;
            worst = MAX(worst, fabs(a - b) / MAX(1.0, MAX(a, b)));
        }
        printf("per-second loudness: worst relative difference %.3f, quiet seconds %lu\n", worst, (unsigned long)silent);
        CHECK(worst < 0.05);

        // Tags as Spotify's scanner reads them (AudioFile info dictionary).
        AudioFileID audioFile = NULL;
        if (AudioFileOpenURL((__bridge CFURLRef)[NSURL fileURLWithPath:path], kAudioFileReadPermission, 0, &audioFile) == noErr) {
            CFDictionaryRef infoDict = NULL;
            UInt32 size = sizeof infoDict;
            AudioFileGetProperty(audioFile, kAudioFilePropertyInfoDictionary, &size, &infoDict);
            NSDictionary *tags = (__bridge_transfer NSDictionary *)infoDict;
            printf("tags: %s\n", tags.description.UTF8String);
            CHECK([tags[@"title"] isEqualToString:entry.title]);
            CHECK([tags[@"album"] isEqualToString:@"SoundCloud"]);
            CHECK([tags[@"artist"] isEqualToString:entry.artist]);
            AudioFileClose(audioFile);
        } else {
            CHECK(!"AudioFileOpenURL failed");
        }
    }
    if (failures) { fprintf(stderr, "%d failed\n", failures); return 1; }
    puts("stream live test passed");
    return 0;
}
