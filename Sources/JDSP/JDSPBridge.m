// JamesDSP as the sound engine behind spotifyglass's Audio effects page.
//
// spotifyglass (the build the user attached, see Scripts/patch_spotifyglass.py) keeps its page, presets,
// AutoEq and file pickers, and they keep writing the spotifyglass.dsp.* preferences. Its own engine is
// switched off by the patch; this file runs libjamesdsp (JDSPEngine, with the bass-priority limiter) on
// Spotify's RemoteIO output instead, reading the same preferences.
//
// The render path: Spotify's executable imports AudioOutputUnitStart; that import is repointed (SCRebind)
// so every output unit Spotify starts gets a post-render notify. The notify hands the finished block to
// JDSPEngine in place. Settings are applied on a serial queue, never on the render thread.
#import <AudioToolbox/AudioToolbox.h>
#import <Foundation/Foundation.h>
#import <dispatch/dispatch.h>
#import <dlfcn.h>
#import <math.h>
#import <stdatomic.h>
#import <string.h>
#import "SCRebind.h"
#import "JDSPEngine.h"
#import "../Core/SCFeatures.h"
#import "../Core/SCLog.h"

static NSString *const kMaster = @"spotifyglass.dsp";
static NSString *const kPostGain = @"spotifyglass.dsp.postGain";
static NSString *const kLimiterThreshold = @"spotifyglass.dsp.limiterThreshold";
static NSString *const kLimiterRelease = @"spotifyglass.dsp.limiterRelease";
static NSString *const kCompander = @"spotifyglass.dsp.compander";
static NSString *const kCompanderTime = @"spotifyglass.dsp.compander.time";
static NSString *const kCompanderGains = @"spotifyglass.dsp.compander.gains";
static NSString *const kBass = @"spotifyglass.dsp.bass";
static NSString *const kBassGain = @"spotifyglass.dsp.bass.gain";
static NSString *const kEQ = @"spotifyglass.dsp.eq";
static NSString *const kEQGains = @"spotifyglass.dsp.eq.gains";
static NSString *const kGEQ = @"spotifyglass.dsp.geq";
static NSString *const kGEQNodes = @"spotifyglass.dsp.geq.nodes";
static NSString *const kConvolver = @"spotifyglass.dsp.convolver";
static NSString *const kConvolverFile = @"spotifyglass.dsp.convolver.file";
static NSString *const kConvolverMode = @"spotifyglass.dsp.convolver.mode";
static NSString *const kDDC = @"spotifyglass.dsp.ddc";
static NSString *const kDDCFile = @"spotifyglass.dsp.ddc.file";
static NSString *const kLiveprog = @"spotifyglass.dsp.liveprog";
static NSString *const kLiveprogFile = @"spotifyglass.dsp.liveprog.file";
static NSString *const kReverb = @"spotifyglass.dsp.reverb";
static NSString *const kReverbPreset = @"spotifyglass.dsp.reverb.preset";
static NSString *const kReverbAmount = @"spotifyglass.dsp.reverb.amount";
static NSString *const kWide = @"spotifyglass.dsp.wide";
static NSString *const kWideLevel = @"spotifyglass.dsp.wide.level";
static NSString *const kCrossfeed = @"spotifyglass.dsp.crossfeed";
static NSString *const kCrossfeedMode = @"spotifyglass.dsp.crossfeed.mode";
static NSString *const kTube = @"spotifyglass.dsp.tube";
static NSString *const kTubeDrive = @"spotifyglass.dsp.tube.drive";

// spotifyglass's own band tables (the same 15 equalizer bands as JamesDSP; its compander bands differ
// from JamesDSP's defaults, so they are read from spotifyglass when it exports them).
static const double kEQFrequencies[15] = {25, 40, 63, 100, 160, 250, 400, 630, 1000, 1600, 2500, 4000, 6300, 10000, 16000};
static double gCompanderFrequencies[7] = {95, 200, 400, 800, 1600, 3400, 7500};

static _Atomic(JDSPEngine *) gEngine;
static atomic_bool gEnabled;
static atomic_uint_fast64_t gLayout;
static atomic_uint_fast64_t gRateBits;
static dispatch_queue_t gConfigQueue;
static OSStatus (*gAudioOutputUnitStart)(AudioUnit);
static NSString *gAppliedSignature;
static BOOL gAppliedEnabled, gHasAppliedEnabled;

static NSArray<NSString *> *settingsKeys(void) {
    static NSArray<NSString *> *keys;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        keys = @[kMaster, kPostGain, kLimiterThreshold, kLimiterRelease, kCompander, kCompanderTime, kCompanderGains,
                 kBass, kBassGain, kEQ, kEQGains, kGEQ, kGEQNodes, kConvolver, kConvolverFile, kConvolverMode,
                 kDDC, kDDCFile, kLiveprog, kLiveprogFile, kReverb, kReverbPreset, kReverbAmount, kWide, kWideLevel,
                 kCrossfeed, kCrossfeedMode, kTube, kTubeDrive];
    });
    return keys;
}

static NSString *settingsSignature(NSUserDefaults *defaults) {
    NSMutableString *signature = [NSMutableString string];
    for (NSString *key in settingsKeys()) {
        id value = [defaults objectForKey:key];
        [signature appendFormat:@"%@=%@\n", key, value ? [value description] : @"<nil>"];
    }
    return signature;
}

static double getDouble(NSUserDefaults *defaults, NSString *key, double fallback) {
    id value = [defaults objectForKey:key];
    return [value respondsToSelector:@selector(doubleValue)] ? [value doubleValue] : fallback;
}

static BOOL getBool(NSUserDefaults *defaults, NSString *key) {
    id value = [defaults objectForKey:key];
    return [value respondsToSelector:@selector(boolValue)] ? [value boolValue] : NO;
}

// Gains are stored as an array of numbers or as "a;b;c" text, depending on where they were set from.
static void readGains(NSUserDefaults *defaults, NSString *key, double *out, NSUInteger count) {
    id value = [defaults objectForKey:key];
    NSArray *parts = @[];
    if ([value isKindOfClass:NSArray.class]) parts = value;
    else if ([value isKindOfClass:NSString.class]) parts = [(NSString *)value componentsSeparatedByString:@";"];
    for (NSUInteger i = 0; i < count; i++) {
        id part = i < parts.count ? parts[i] : nil;
        double gain = [part respondsToSelector:@selector(doubleValue)] ? [part doubleValue] : 0;
        out[i] = isfinite(gain) ? gain : 0;
    }
}

// spotifyglass keeps imported files under Documents/spoti.pw/JamesDSP; the preference holds a file name
// (or, from an imported preset, a relative or absolute path). The file is found wherever it sits there.
static NSString *libraryFile(NSString *stored) {
    if (![stored isKindOfClass:NSString.class] || !stored.length) return nil;
    NSFileManager *files = NSFileManager.defaultManager;
    if (stored.isAbsolutePath && [files fileExistsAtPath:stored]) return stored;
    NSString *documents = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
    NSString *root = [documents stringByAppendingPathComponent:@"spoti.pw/JamesDSP"];
    NSString *direct = [root stringByAppendingPathComponent:stored];
    if ([files fileExistsAtPath:direct]) return direct;
    NSString *name = stored.lastPathComponent;
    NSDirectoryEnumerator *walk = [files enumeratorAtPath:root];
    for (NSString *relative in walk) {
        if ([relative.lastPathComponent isEqualToString:name]) return [root stringByAppendingPathComponent:relative];
    }
    return nil;
}

static void applySettings(void) {
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    BOOL enabled = getBool(defaults, kMaster);
    atomic_store_explicit(&gEnabled, enabled, memory_order_release);
    JDSPEngine *engine = atomic_load_explicit(&gEngine, memory_order_acquire);
    if (!engine) return;
    NSString *signature = settingsSignature(defaults);
    BOOL enabledChanged = !gHasAppliedEnabled || gAppliedEnabled != enabled;
    if (gAppliedSignature && [gAppliedSignature isEqualToString:signature]) return;

    JDSPEngineSetOutput(engine, getDouble(defaults, kPostGain, 0), getDouble(defaults, kLimiterThreshold, -0.1),
                        getDouble(defaults, kLimiterRelease, 60));

    double compander[7], eq[15];
    readGains(defaults, kCompanderGains, compander, 7);
    JDSPEngineSetCompander(engine, getBool(defaults, kCompander), getDouble(defaults, kCompanderTime, 0.22), 2, 0,
                           gCompanderFrequencies, compander);
    JDSPEngineSetBassBoost(engine, getBool(defaults, kBass), getDouble(defaults, kBassGain, 0));
    readGains(defaults, kEQGains, eq, 15);
    JDSPEngineSetEqualizer(engine, getBool(defaults, kEQ), 0, 0, kEQFrequencies, eq);

    char error[256] = {0};
    NSString *nodes = [defaults objectForKey:kGEQNodes];
    if (![nodes isKindOfClass:NSString.class] || !nodes.length) nodes = @"GraphicEQ: 0.0 0.0;";
    if (!JDSPEngineSetGraphicEq(engine, getBool(defaults, kGEQ), nodes.UTF8String, error, sizeof error) && error[0]) {
        SCLog(@"jdsp", @"graphic EQ: %s", error);
    }
    NSString *convolver = libraryFile([defaults objectForKey:kConvolverFile]);
    error[0] = 0;
    if (!JDSPEngineSetConvolver(engine, getBool(defaults, kConvolver) && convolver.length, convolver.UTF8String,
                                (int)getDouble(defaults, kConvolverMode, 0), "-80;-100;0;0;0;0", error, sizeof error) && error[0]) {
        SCLog(@"jdsp", @"convolver %@: %s", convolver, error);
    }
    NSString *ddcPath = libraryFile([defaults objectForKey:kDDCFile]);
    NSString *ddc = ddcPath ? [NSString stringWithContentsOfFile:ddcPath encoding:NSUTF8StringEncoding error:nil] : nil;
    error[0] = 0;
    if (!JDSPEngineSetDDC(engine, getBool(defaults, kDDC) && ddc.length, ddc.UTF8String, error, sizeof error) && error[0]) {
        SCLog(@"jdsp", @"DDC %@: %s", ddcPath, error);
    }
    NSString *liveprogPath = libraryFile([defaults objectForKey:kLiveprogFile]);
    NSString *liveprog = liveprogPath ? [NSString stringWithContentsOfFile:liveprogPath encoding:NSUTF8StringEncoding error:nil] : nil;
    error[0] = 0;
    if (!JDSPEngineSetLiveprog(engine, getBool(defaults, kLiveprog) && liveprog.length, liveprog.UTF8String, error, sizeof error) && error[0]) {
        SCLog(@"jdsp", @"Liveprog %@: %s", liveprogPath, error);
    }
    // spotifyglass's reverb has an amount; JamesDSP's has presets only, so the amount just turns it off at 0.
    BOOL reverb = getBool(defaults, kReverb) && getDouble(defaults, kReverbAmount, 1) > 0;
    JDSPEngineSetReverb(engine, reverb, (int)getDouble(defaults, kReverbPreset, 9));
    JDSPEngineSetStereoWide(engine, getBool(defaults, kWide), getDouble(defaults, kWideLevel, 60));
    JDSPEngineSetCrossfeed(engine, getBool(defaults, kCrossfeed), (int)getDouble(defaults, kCrossfeedMode, 5));
    JDSPEngineSetTube(engine, getBool(defaults, kTube), getDouble(defaults, kTubeDrive, 2));
    if (enabledChanged) JDSPEngineRestart(engine);
    gAppliedSignature = [signature copy];
    gAppliedEnabled = enabled;
    gHasAppliedEnabled = YES;
    SCLog(@"jdsp", @"settings applied (effects %@)", enabled ? @"on" : @"off");
}

static inline float readSample(const void *data, UInt32 index, UInt32 bytes, BOOL isFloat, UInt32 fraction) {
    if (bytes == 4 && isFloat) return ((const float *)data)[index];
    if (bytes == 4) {
        int32_t value = ((const int32_t *)data)[index];
        return fraction ? (float)((double)value / (double)(1u << fraction)) : (float)(value / 2147483648.0);
    }
    return (float)((const int16_t *)data)[index] / 32768.0f;
}

static inline void writeSample(void *data, UInt32 index, float value, UInt32 bytes, BOOL isFloat, UInt32 fraction) {
    if (bytes == 4 && isFloat) {
        ((float *)data)[index] = value;
        return;
    }
    value = fmaxf(-1, fminf(1, value));
    if (bytes == 4) {
        double scale = fraction ? (double)(1u << fraction) : 2147483647.0;
        ((int32_t *)data)[index] = (int32_t)(value * scale);
    } else {
        ((int16_t *)data)[index] = (int16_t)(value * 32767.0f);
    }
}

static float gLeft[4096], gRight[4096];

static void processBuffers(JDSPEngine *engine, AudioUnitRenderActionFlags *flags, UInt32 frames, AudioBufferList *data) {
    uint64_t layout = atomic_load_explicit(&gLayout, memory_order_relaxed);
    UInt32 formatFlags = (UInt32)layout, channels = (UInt32)(layout >> 32) & 0xffff, bytes = (UInt32)(layout >> 48);
    BOOL isFloat = (formatFlags & kAudioFormatFlagIsFloat) != 0;
    BOOL split = (formatFlags & kAudioFormatFlagIsNonInterleaved) != 0;
    UInt32 fraction = (formatFlags & kLinearPCMFormatFlagsSampleFractionMask) >> kLinearPCMFormatFlagsSampleFractionShift;
    if ((bytes != 2 && bytes != 4) || channels < 1) return;

    UInt32 needed = frames * bytes * (split ? 1 : channels);
    BOOL fits = split ? data->mNumberBuffers >= channels : data->mNumberBuffers == 1;
    for (UInt32 b = 0; fits && b < (split ? channels : 1); b++) {
        fits = data->mBuffers[b].mData && data->mBuffers[b].mDataByteSize >= needed;
    }
    if (!fits) return;

    BOOL silent = (*flags & kAudioUnitRenderAction_OutputIsSilence) != 0;
    if (split && isFloat && bytes == 4 && channels >= 2) {
        float *left = data->mBuffers[0].mData, *right = data->mBuffers[1].mData;
        if (silent) {
            memset(left, 0, frames * sizeof(float));
            memset(right, 0, frames * sizeof(float));
        }
        JDSPEngineProcess(engine, left, right, frames);
    } else {
        for (UInt32 done = 0; done < frames;) {
            UInt32 count = MIN(frames - done, (UInt32)4096);
            const void *first = data->mBuffers[0].mData;
            const void *second = split && channels > 1 ? data->mBuffers[1].mData : first;
            UInt32 stride = split ? 1 : channels, secondOffset = !split && channels > 1 ? 1 : 0;
            for (UInt32 i = 0; i < count; i++) {
                UInt32 at = (done + i) * stride;
                gLeft[i] = silent ? 0 : readSample(first, at, bytes, isFloat, fraction);
                gRight[i] = silent ? 0 : readSample(second, at + secondOffset, bytes, isFloat, fraction);
            }
            JDSPEngineProcess(engine, gLeft, gRight, count);
            void *firstOut = data->mBuffers[0].mData;
            void *secondOut = split && channels > 1 ? data->mBuffers[1].mData : firstOut;
            for (UInt32 i = 0; i < count; i++) {
                UInt32 at = (done + i) * stride;
                if (channels == 1) {
                    writeSample(firstOut, at, 0.5f * (gLeft[i] + gRight[i]), bytes, isFloat, fraction);
                } else {
                    writeSample(firstOut, at, gLeft[i], bytes, isFloat, fraction);
                    writeSample(secondOut, at + secondOffset, gRight[i], bytes, isFloat, fraction);
                }
            }
            done += count;
        }
    }
    // A silent block stays marked silent (the engine's one-block tail is dropped then, as before).
    if (!silent) *flags &= ~kAudioUnitRenderAction_OutputIsSilence;
}

static OSStatus rendered(void *refCon, AudioUnitRenderActionFlags *flags, const AudioTimeStamp *timestamp,
                         UInt32 bus, UInt32 frames, AudioBufferList *data) {
    if (!(*flags & kAudioUnitRenderAction_PostRender) || bus != 0 || !data || !data->mNumberBuffers || !frames) return noErr;
    if (!atomic_load_explicit(&gEnabled, memory_order_acquire)) return noErr;
    JDSPEngine *engine = atomic_load_explicit(&gEngine, memory_order_acquire);
    if (!engine) return noErr;
    uint64_t rateBits = atomic_load_explicit(&gRateBits, memory_order_relaxed);
    double rate;
    memcpy(&rate, &rateBits, sizeof rate);
    if (rate <= 0 || JDSPEngineSampleRate(engine) != rate) return noErr;
    processBuffers(engine, flags, frames, data);
    return noErr;
}

static BOOL isRemoteIO(AudioUnit unit) {
    AudioComponentDescription description = {0};
    return unit && AudioComponentGetDescription(AudioComponentInstanceGetComponent(unit), &description) == noErr &&
           description.componentType == kAudioUnitType_Output && description.componentSubType == kAudioUnitSubType_RemoteIO;
}

static void updateFormat(AudioUnit unit) {
    if (!isRemoteIO(unit)) return;
    AudioStreamBasicDescription format = {0};
    UInt32 size = sizeof format;
    if (AudioUnitGetProperty(unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, 0, &format, &size) != noErr ||
        format.mFormatID != kAudioFormatLinearPCM || (format.mBitsPerChannel != 16 && format.mBitsPerChannel != 32) ||
        format.mSampleRate <= 0 || format.mChannelsPerFrame < 1) {
        atomic_store(&gLayout, 0);
        atomic_store(&gRateBits, 0);
        return;
    }
    UInt32 bytes = format.mBitsPerChannel / 8;
    atomic_store(&gLayout, (uint64_t)format.mFormatFlags | (uint64_t)(format.mChannelsPerFrame & 0xffff) << 32 | (uint64_t)bytes << 48);
    uint64_t rateBits;
    memcpy(&rateBits, &format.mSampleRate, sizeof rateBits);
    atomic_store(&gRateBits, rateBits);
    double rate = format.mSampleRate;
    dispatch_async(gConfigQueue, ^{
        JDSPEngine *old = atomic_load(&gEngine);
        if (!old || JDSPEngineSampleRate(old) != rate) {
            JDSPEngine *fresh = JDSPEngineCreate(rate);
            if (!fresh) {
                SCLog(@"jdsp", @"could not create the engine at %.0f Hz", rate);
                return;
            }
            // The render thread may still hold the old engine for this block; old engines are kept for the
            // process's life (a rate change is rare: a new audio route).
            atomic_store(&gEngine, fresh);
            gAppliedSignature = nil;
            SCLog(@"jdsp", @"JamesDSP ready at %.0f Hz", rate);
        }
        applySettings();
    });
}

static void formatChanged(void *refCon, AudioUnit unit, AudioUnitPropertyID property, AudioUnitScope scope, AudioUnitElement element) {
    if (property == kAudioUnitProperty_StreamFormat && scope == kAudioUnitScope_Output && element == 0) updateFormat(unit);
}

static OSStatus startOutput(AudioUnit unit) {
    OSStatus status = gAudioOutputUnitStart ? gAudioOutputUnitStart(unit) : -1;
    if (status == noErr && isRemoteIO(unit)) {
        AudioUnitRemovePropertyListenerWithUserData(unit, kAudioUnitProperty_StreamFormat, formatChanged, NULL);
        AudioUnitAddPropertyListener(unit, kAudioUnitProperty_StreamFormat, formatChanged, NULL);
        updateFormat(unit);
        AudioUnitRemoveRenderNotify(unit, rendered, NULL);
        AudioUnitAddRenderNotify(unit, rendered, NULL);
    }
    return status;
}

static void loadCompanderBands(void) {
    // Exported by spotifyglass; an older or newer build without it keeps the table above.
    const double *bands = dlsym(RTLD_DEFAULT, "SGDSPCompanderFrequencies");
    if (!bands) return;
    for (int i = 0; i < 7; i++) {
        if (!isfinite(bands[i]) || bands[i] < 10 || bands[i] > 22000) return;
    }
    memcpy(gCompanderFrequencies, bands, sizeof gCompanderFrequencies);
}

void SCJamesDSPStart(void) {
    gConfigQueue = dispatch_queue_create("spotcloud.jdsp", DISPATCH_QUEUE_SERIAL);
    loadCompanderBands();
    if (!SCRebindImport("AudioOutputUnitStart", (void *)startOutput, (void **)&gAudioOutputUnitStart) || !gAudioOutputUnitStart) {
        SCLog(@"jdsp", @"Spotify does not import AudioOutputUnitStart; JamesDSP stays off");
        return;
    }
    dispatch_async(gConfigQueue, ^{ applySettings(); });
    [NSNotificationCenter.defaultCenter addObserverForName:NSUserDefaultsDidChangeNotification object:nil queue:nil
                                                usingBlock:^(NSNotification *note) {
        dispatch_async(gConfigQueue, ^{ applySettings(); });
    }];
    // Some of spotifyglass's writes go through a suite that posts no notification; a slow poll catches them.
    dispatch_source_t timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, gConfigQueue);
    dispatch_source_set_timer(timer, dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC), NSEC_PER_SEC, NSEC_PER_MSEC * 100);
    dispatch_source_set_event_handler(timer, ^{ applySettings(); });
    dispatch_resume(timer);
    SCLog(@"jdsp", @"JamesDSP bridge loaded");
}
