// The output limiter, in place of libjamesdsp's own, which takes the whole sound down whenever it is over the
// threshold: a bass boost on music mastered to full scale is over it on every beat, so the voice and the
// highs dropped with each kick and came back between them.
//
// This one splits the sound at kJDSPBassLimiterCrossover with a Linkwitz-Riley crossover (fourth order, the
// bands sum flat) and takes only the low band down until the peak fits, the rest left as it is. Only when
// the highs alone are over the threshold does the whole sound come down, as the old limiter did. Both gains
// look ahead (the sound is kJDSPBassLimiterLatency frames late) and ramp in over that time, so a peak never
// gets through and the gain never jumps; the low band's comes back over a fixed kJDSPBassLimiterBassRelease
// rather than the limiter's release, which, shorter than a bass wave, would shape the wave itself.
//
// Plain C. The state is the render thread's alone; JDSPBassLimiterProcess never allocates, blocks or logs.
#pragma once
#include <stdint.h>

#define kJDSPBassLimiterCrossover 160.0      // Hz
#define kJDSPBassLimiterBassRelease 200.0    // ms
#define kJDSPBassLimiterBassHold 30.0        // ms
#define kJDSPBassLimiterBassFloor 0.1f       // the most the low band is taken down, -20 dB

enum {
    kJDSPBassLimiterBassLook = 256,          // frames the low band's gain ramps over (5.3 ms at 48 kHz)
    kJDSPBassLimiterPeakLook = 64,           // the whole sound's
    kJDSPBassLimiterLatency = kJDSPBassLimiterBassLook - 1 + kJDSPBassLimiterPeakLook - 1,
};

typedef struct {
    double b0, b1, b2, a1, a2;
} JLBiquadCoefficients;

typedef struct {
    double z1, z2;
} JLBiquadState;

// The smallest of the last `look` values, a gain held and released from it, and its average over `look`.
typedef struct {
    uint64_t head, tail;                   // the queue of candidates for the minimum
    uint64_t index[512];
    float value[512];
    float held;
    uint32_t holdLeft;
    float ramp[512];
    double rampSum;
} JLLimiterGain;

typedef struct {
    // Configuration, made from the rate, threshold and release by JDSPBassLimiterConfigure.
    double rate, thresholdDB, releaseMS;
    float threshold;
    float bassRelease, peakRelease;        // per frame
    uint32_t bassHold;                     // frames
    JLBiquadCoefficients low, high;

    JLBiquadState lowState[2][2], highState[2][2];  // [channel][section]
    uint64_t frame;
    JLLimiterGain bass, peak;
    float lowDelay[2][kJDSPBassLimiterBassLook], highDelay[2][kJDSPBassLimiterBassLook];
    float peakDelay[2][kJDSPBassLimiterPeakLook];

    // What it did, for the diagnostics: the lowest gains since they were last read.
    float lowestBass, lowestPeak;
} JDSPBassLimiter;

// Starts over, silent and with no gain taken. The configuration stays.
void JDSPBassLimiterReset(JDSPBassLimiter *limiter);
// Cheap when nothing changed; a new rate starts the crossover over.
void JDSPBassLimiterConfigure(JDSPBassLimiter *limiter, double rate, double thresholdDB, double releaseMS);
// In place; the output is kJDSPBassLimiterLatency frames behind the input.
void JDSPBassLimiterProcess(JDSPBassLimiter *limiter, float *left, float *right, uint32_t frames);
