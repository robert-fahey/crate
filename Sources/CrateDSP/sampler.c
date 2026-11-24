// The sampler's audio-thread code. Like the deck: no allocation, no locks and
// nothing of the Swift runtime while rendering. Commands arrive on a queue.

#include "CrateDSP.h"

#include <math.h>
#include <stdatomic.h>
#include <stdlib.h>
#include <string.h>

#define PADS CRATE_SAMPLER_PADS
#define VOICES_PER_PAD 2
#define AUDIO_SLOTS 4
#define QUEUE_SIZE 256  // a power of two

typedef enum { SamplerAudio, SamplerTrigger, SamplerStop, SamplerPad } SamplerCommandType;

typedef struct {
    int32_t type;
    int32_t pad;
    int32_t slot;
    double a;
    double b;
} SamplerCommand;

typedef struct {
    const float *left;
    const float *right;
    int64_t frames;
    double sampleRate;
} PadAudio;

typedef struct {
    PadAudio audio;
    double position;  // source frames
    double step;      // source frames per engine frame
    float level;      // the fade: 1 while sounding, falling to 0 when let go
    bool active;
    bool releasing;
} Voice;

struct CrateSampler {
    double fs;
    // Control thread to audio thread.
    SamplerCommand queue[QUEUE_SIZE];
    _Atomic uint32_t queueWrite;
    _Atomic uint32_t queueRead;
    PadAudio slots[PADS][AUDIO_SLOTS];
    int nextSlot[PADS];  // control thread only
    _Atomic double master, cue, monitor;

    // Audio thread to control thread.
    _Atomic uint32_t playingMask;
    _Atomic float progress[PADS];

    // Audio thread only from here down.
    PadAudio audio[PADS];
    float gain[PADS];
    bool loops[PADS];
    Voice voices[PADS][VOICES_PER_PAD];
    double masterNow, cueNow, monitorNow;
    float release;  // what a voice's level falls by each frame once let go
    double glide;   // how fast the levels follow the knobs
};

CrateSampler *crate_sampler_create(double engineSampleRate) {
    CrateSampler *sampler = calloc(1, sizeof(CrateSampler));
    if (!sampler) return NULL;
    sampler->fs = engineSampleRate > 0 ? engineSampleRate : 44100;
    for (int pad = 0; pad < PADS; pad++) sampler->gain[pad] = 1;
    atomic_store(&sampler->master, 1.0);
    sampler->masterNow = 1;
    sampler->release = (float)(1.0 / (0.004 * sampler->fs));  // 4 ms
    sampler->glide = 1.0 - exp(-1.0 / (0.01 * sampler->fs));
    return sampler;
}

void crate_sampler_destroy(CrateSampler *sampler) { free(sampler); }

static bool send(CrateSampler *sampler, SamplerCommand command) {
    uint32_t write = atomic_load_explicit(&sampler->queueWrite, memory_order_relaxed);
    uint32_t read = atomic_load_explicit(&sampler->queueRead, memory_order_acquire);
    if (write - read >= QUEUE_SIZE) return false;
    sampler->queue[write & (QUEUE_SIZE - 1)] = command;
    atomic_store_explicit(&sampler->queueWrite, write + 1, memory_order_release);
    return true;
}

static bool isPad(int32_t pad) { return pad >= 0 && pad < PADS; }

bool crate_sampler_set_audio(CrateSampler *sampler, int32_t pad, const float *left, const float *right, int64_t frames, double sampleRate) {
    if (!isPad(pad)) return false;
    int slot = sampler->nextSlot[pad];
    sampler->nextSlot[pad] = (slot + 1) % AUDIO_SLOTS;
    bool usable = left && frames > 0 && sampleRate > 0;
    sampler->slots[pad][slot] = usable ? (PadAudio){left, right ? right : left, frames, sampleRate} : (PadAudio){0};
    return send(sampler, (SamplerCommand){.type = SamplerAudio, .pad = pad, .slot = slot});
}

bool crate_sampler_trigger(CrateSampler *sampler, int32_t pad) {
    return isPad(pad) && send(sampler, (SamplerCommand){.type = SamplerTrigger, .pad = pad});
}

bool crate_sampler_stop(CrateSampler *sampler, int32_t pad) {
    return pad < PADS && send(sampler, (SamplerCommand){.type = SamplerStop, .pad = pad});
}

bool crate_sampler_set_pad(CrateSampler *sampler, int32_t pad, double gain, bool loops) {
    return isPad(pad) && send(sampler, (SamplerCommand){.type = SamplerPad, .pad = pad, .a = gain, .b = loops ? 1 : 0});
}

void crate_sampler_set_levels(CrateSampler *sampler, double master, double cue, double monitor) {
    atomic_store_explicit(&sampler->master, master, memory_order_relaxed);
    atomic_store_explicit(&sampler->cue, cue, memory_order_relaxed);
    atomic_store_explicit(&sampler->monitor, monitor, memory_order_relaxed);
}

void crate_sampler_snapshot(CrateSampler *sampler, CrateSamplerSnapshot *out) {
    uint32_t mask = atomic_load_explicit(&sampler->playingMask, memory_order_relaxed);
    for (int pad = 0; pad < PADS; pad++) {
        out->playing[pad] = (mask >> pad) & 1;
        out->progress[pad] = atomic_load_explicit(&sampler->progress[pad], memory_order_relaxed);
    }
}

static void letGo(CrateSampler *sampler, int pad) {
    for (int v = 0; v < VOICES_PER_PAD; v++) {
        if (sampler->voices[pad][v].active) sampler->voices[pad][v].releasing = true;
    }
}

static void apply(CrateSampler *sampler, const SamplerCommand *command) {
    int pad = command->pad;
    switch (command->type) {
    case SamplerAudio:
        // What is sounding fades out of the old audio, which its owner keeps a moment longer for that.
        letGo(sampler, pad);
        sampler->audio[pad] = sampler->slots[pad][command->slot];
        break;
    case SamplerTrigger: {
        if (!sampler->audio[pad].left) break;
        letGo(sampler, pad);
        // The voice that is free, or failing that the quieter of the two.
        Voice *voice = &sampler->voices[pad][0];
        for (int v = 0; v < VOICES_PER_PAD; v++) {
            Voice *candidate = &sampler->voices[pad][v];
            if (!candidate->active) { voice = candidate; break; }
            if (candidate->level < voice->level) voice = candidate;
        }
        // No fade in: a drum's attack is in the first few samples.
        *voice = (Voice){
            .audio = sampler->audio[pad], .position = 0, .step = sampler->audio[pad].sampleRate / sampler->fs,
            .level = 1, .active = true, .releasing = false};
        break;
    }
    case SamplerStop:
        if (pad < 0) {
            for (int each = 0; each < PADS; each++) letGo(sampler, each);
        } else {
            letGo(sampler, pad);
        }
        break;
    case SamplerPad:
        sampler->gain[pad] = (float)fmax(0, command->a);
        sampler->loops[pad] = command->b != 0;
        break;
    }
}

void crate_sampler_render(CrateSampler *sampler, float *left, float *right, float *phonesLeft, float *phonesRight, int32_t frames) {
    uint32_t read = atomic_load_explicit(&sampler->queueRead, memory_order_relaxed);
    uint32_t write = atomic_load_explicit(&sampler->queueWrite, memory_order_acquire);
    while (read != write) {
        apply(sampler, &sampler->queue[read & (QUEUE_SIZE - 1)]);
        read++;
    }
    atomic_store_explicit(&sampler->queueRead, read, memory_order_release);

    memset(left, 0, (size_t)frames * sizeof(float));
    memset(right, 0, (size_t)frames * sizeof(float));

    uint32_t mask = 0;
    for (int pad = 0; pad < PADS; pad++) {
        float furthest = 0;
        for (int v = 0; v < VOICES_PER_PAD; v++) {
            Voice *voice = &sampler->voices[pad][v];
            if (!voice->active) continue;
            const PadAudio audio = voice->audio;
            const float gain = sampler->gain[pad];
            const bool loops = sampler->loops[pad] && !voice->releasing;
            for (int32_t i = 0; i < frames; i++) {
                if (voice->position >= (double)audio.frames) {
                    if (!loops) { voice->active = false; break; }
                    voice->position = fmod(voice->position, (double)audio.frames);
                }
                int64_t index = (int64_t)voice->position;
                float fraction = (float)(voice->position - (double)index);
                // The sample after the last is the first when looping, silence otherwise.
                int64_t next = index + 1 < audio.frames ? index + 1 : (loops ? 0 : -1);
                float l = audio.left[index], r = audio.right[index];
                l += ((next >= 0 ? audio.left[next] : 0) - l) * fraction;
                r += ((next >= 0 ? audio.right[next] : 0) - r) * fraction;
                float level = voice->level * gain;
                left[i] += l * level;
                right[i] += r * level;
                voice->position += voice->step;
                if (voice->releasing) {
                    voice->level -= sampler->release;
                    if (voice->level <= 0) { voice->active = false; break; }
                }
            }
            if (voice->active && !voice->releasing) {
                mask |= 1u << pad;
                float through = audio.frames > 0 ? (float)(voice->position / (double)audio.frames) : 0;
                if (through > furthest) furthest = through;
            }
        }
        atomic_store_explicit(&sampler->progress[pad], furthest > 1 ? 1 : furthest, memory_order_relaxed);
    }
    atomic_store_explicit(&sampler->playingMask, mask, memory_order_relaxed);

    // Into the mix at the sampler's level; to the headphones by the cue, whatever that level is.
    const double master = atomic_load_explicit(&sampler->master, memory_order_relaxed);
    const double cue = atomic_load_explicit(&sampler->cue, memory_order_relaxed);
    const double monitor = atomic_load_explicit(&sampler->monitor, memory_order_relaxed);
    for (int32_t i = 0; i < frames; i++) {
        sampler->masterNow += (master - sampler->masterNow) * sampler->glide;
        sampler->cueNow += (cue - sampler->cueNow) * sampler->glide;
        sampler->monitorNow += (monitor - sampler->monitorNow) * sampler->glide;
        float l = left[i], r = right[i];
        left[i] = (float)(l * sampler->masterNow);
        right[i] = (float)(r * sampler->masterNow);
        if (phonesLeft && phonesRight) {
            double share = sampler->cueNow + sampler->masterNow * sampler->monitorNow;
            phonesLeft[i] = (float)(l * share);
            phonesRight[i] = (float)(r * share);
        }
    }
}
