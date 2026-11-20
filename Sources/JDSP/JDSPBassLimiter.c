// JDSPBassLimiter.h says what this is.
#include "JDSPBassLimiter.h"
#include <math.h>
#include <string.h>

enum { kGainMask = 511 };

// the crossover

// A second order Butterworth section (RBJ's cookbook); two of them in a row make each Linkwitz-Riley band.
static JLBiquadCoefficients butterworth(double rate, double frequency, int highPass) {
    double w = 2 * M_PI * frequency / rate, c = cos(w), alpha = sin(w) / (2 * M_SQRT1_2);
    double a0 = 1 + alpha;
    double edge = highPass ? (1 + c) / 2 : (1 - c) / 2;
    return (JLBiquadCoefficients){
        .b0 = edge / a0,
        .b1 = (highPass ? -2 * edge : 2 * edge) / a0,
        .b2 = edge / a0,
        .a1 = -2 * c / a0,
        .a2 = (1 - alpha) / a0,
    };
}

static inline double biquad(const JLBiquadCoefficients *k, JLBiquadState *s, double x) {
    double y = k->b0 * x + s->z1;
    s->z1 = k->b1 * x - k->a1 * y + s->z2;
    s->z2 = k->b2 * x - k->a2 * y;
    return y;
}

// a gain that looks ahead

static void resetGain(JLLimiterGain *gain) {
    gain->head = gain->tail = 0;
    gain->held = 1;
    gain->holdLeft = 0;
    for (int i = 0; i <= kGainMask; i++) gain->ramp[i] = 1;
    gain->rampSum = 0;
}

// The gain for the frame `look - 1` before this one, given the gain this frame needs. Every gain the average
// takes in is at most the smallest needed over the `look` frames before it, so the frame it is for, which is
// in each of those windows, never gets more than it needed.
static inline float stepGain(JLLimiterGain *gain, uint64_t frame, uint32_t look, float needed, float release,
                             uint32_t hold) {
    while (gain->tail > gain->head && gain->value[(gain->tail - 1) & kGainMask] >= needed) gain->tail--;
    gain->index[gain->tail & kGainMask] = frame;
    gain->value[gain->tail & kGainMask] = needed;
    gain->tail++;
    while (gain->index[gain->head & kGainMask] + look <= frame) gain->head++;
    float smallest = gain->value[gain->head & kGainMask];

    float held = gain->held;
    if (smallest < held) {
        held = smallest;
        gain->holdLeft = hold;
    } else if (gain->holdLeft) {
        gain->holdLeft--;
    } else {
        held = 1 + (held - 1) * release;
        if (held > smallest) held = smallest;
    }
    gain->held = held;

    gain->rampSum += held - gain->ramp[(frame - look) & kGainMask];
    gain->ramp[frame & kGainMask] = held;
    // The running sum drifts by rounding; it is started over from the ring now and then.
    if ((frame & 0xFFFF) == 0) {
        double sum = 0;
        for (uint32_t i = 0; i < look; i++) sum += gain->ramp[(frame - i) & kGainMask];
        gain->rampSum = sum;
    }
    float average = (float)(gain->rampSum / look);
    return average > 1 ? 1 : average;
}

// the limiter

void JDSPBassLimiterReset(JDSPBassLimiter *limiter) {
    memset(limiter->lowState, 0, sizeof limiter->lowState);
    memset(limiter->highState, 0, sizeof limiter->highState);
    memset(limiter->lowDelay, 0, sizeof limiter->lowDelay);
    memset(limiter->highDelay, 0, sizeof limiter->highDelay);
    memset(limiter->peakDelay, 0, sizeof limiter->peakDelay);
    // Started at the size of the longer window so that `frame - look` never goes below zero.
    limiter->frame = kGainMask + 1;
    resetGain(&limiter->bass);
    resetGain(&limiter->peak);
    limiter->bass.rampSum = kJDSPBassLimiterBassLook;
    limiter->peak.rampSum = kJDSPBassLimiterPeakLook;
    limiter->lowestBass = limiter->lowestPeak = 1;
}

void JDSPBassLimiterConfigure(JDSPBassLimiter *limiter, double rate, double thresholdDB, double releaseMS) {
    if (rate == limiter->rate && thresholdDB == limiter->thresholdDB && releaseMS == limiter->releaseMS) return;
    if (!(rate >= 8000)) return;
    if (releaseMS < 1.5) releaseMS = 1.5;
    if (rate != limiter->rate) {
        limiter->low = butterworth(rate, kJDSPBassLimiterCrossover, 0);
        limiter->high = butterworth(rate, kJDSPBassLimiterCrossover, 1);
        limiter->bassRelease = (float)exp(-1000.0 / (kJDSPBassLimiterBassRelease * rate));
        limiter->bassHold = (uint32_t)(kJDSPBassLimiterBassHold * rate / 1000);
        JDSPBassLimiterReset(limiter);
    }
    limiter->rate = rate;
    limiter->thresholdDB = thresholdDB;
    limiter->releaseMS = releaseMS;
    limiter->threshold = (float)pow(10.0, thresholdDB / 20.0);
    limiter->peakRelease = (float)exp(-1000.0 / (releaseMS * rate));
}

// What the low band may keep of itself for |high + gain * low| to fit under the threshold. Highs over it on
// their own are the whole sound's to take down; the low band only gives up the room they leave, counted as
// if they stopped at 90% of the threshold, so a loud snare doesn't empty the bass.
static inline float bassRoom(float high, float low, float threshold) {
    float cap = 0.9f * threshold;
    if (high > cap) high = cap;
    if (high < -cap) high = -cap;
    float sum = high + low;
    if (fabsf(sum) <= threshold) return 1;
    // high + gain * low runs in a line from high (under) to sum (over); it meets the threshold on sum's side.
    float gain = ((sum > 0 ? threshold : -threshold) - high) / low;
    return gain < kJDSPBassLimiterBassFloor ? kJDSPBassLimiterBassFloor : gain;
}

void JDSPBassLimiterProcess(JDSPBassLimiter *limiter, float *left, float *right, uint32_t frames) {
    float threshold = limiter->threshold;
    float *lanes[2] = {left, right};
    for (uint32_t i = 0; i < frames; i++) {
        uint64_t frame = limiter->frame++;
        uint32_t bassAt = (uint32_t)(frame % kJDSPBassLimiterBassLook);
        uint32_t peakAt = (uint32_t)(frame % kJDSPBassLimiterPeakLook);

        float room = 1;
        for (int c = 0; c < 2; c++) {
            double x = lanes[c][i];
            double low = biquad(&limiter->low, &limiter->lowState[c][1], biquad(&limiter->low, &limiter->lowState[c][0], x));
            double high = biquad(&limiter->high, &limiter->highState[c][1], biquad(&limiter->high, &limiter->highState[c][0], x));
            float r = bassRoom((float)high, (float)low, threshold);
            if (r < room) room = r;
            // The delay line's oldest frame is look - 1 behind the one about to go in.
            limiter->lowDelay[c][bassAt] = (float)low;
            limiter->highDelay[c][bassAt] = (float)high;
        }
        float bassGain = stepGain(&limiter->bass, frame, kJDSPBassLimiterBassLook, room, limiter->bassRelease, limiter->bassHold);
        uint32_t bassOut = (uint32_t)((frame + 1) % kJDSPBassLimiterBassLook);

        float mixed[2], loudest = 0;
        for (int c = 0; c < 2; c++) {
            mixed[c] = limiter->highDelay[c][bassOut] + bassGain * limiter->lowDelay[c][bassOut];
            float level = fabsf(mixed[c]);
            if (level > loudest) loudest = level;
            limiter->peakDelay[c][peakAt] = mixed[c];
        }
        float needed = loudest > threshold ? threshold / loudest : 1;
        float peakGain = stepGain(&limiter->peak, frame, kJDSPBassLimiterPeakLook, needed, limiter->peakRelease, 0);
        uint32_t peakOut = (uint32_t)((frame + 1) % kJDSPBassLimiterPeakLook);

        for (int c = 0; c < 2; c++) {
            float y = limiter->peakDelay[c][peakOut] * peakGain;
            // Rounding alone could take it past; nothing else can.
            if (y > threshold) y = threshold;
            if (y < -threshold) y = -threshold;
            lanes[c][i] = y;
        }
        if (bassGain < limiter->lowestBass) limiter->lowestBass = bassGain;
        if (peakGain < limiter->lowestPeak) limiter->lowestPeak = peakGain;
    }
}
