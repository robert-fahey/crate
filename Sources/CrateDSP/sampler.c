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

typedef enum { SamplerAudio, SamplerTrigger, SamplerStop, SamplerPad, SamplerRate } SamplerCommandType;

typedef struct {
    int32_t type;
    int32_t pad;
    int32_t slot;
    int64_t atFrame;  // for a trigger: the frame of the sampler's own count to start on; 0 = straight away
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
    float level;      // the fade: 1 while sounding, falling to 0 when let go
    bool active;
    bool releasing;
    bool rising;      // started part-way through its audio, so faded in rather than cut in
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

    // Audio thread to control thread, guarded by a sequence counter.
    _Atomic uint32_t sequence;
    CrateSamplerSnapshot published;

    // Audio thread only from here down.
    int64_t frame;  // frames rendered
    PadAudio audio[PADS];
    float gain[PADS];
    bool loops[PADS];
    double rate[PADS];  // speed, 1 = as recorded
    Voice voices[PADS][VOICES_PER_PAD];
    // A hit that is waiting for its frame: one to a pad, the latest.
    bool waiting[PADS];
    int64_t waitFrame[PADS];
    double waitPosition[PADS], waitRate[PADS];
    double masterNow, cueNow, monitorNow;
    float release;  // what a voice's level falls by each frame once let go
    double glide;   // how fast the levels follow the knobs
};

CrateSampler *crate_sampler_create(double engineSampleRate) {
    CrateSampler *sampler = calloc(1, sizeof(CrateSampler));
    if (!sampler) return NULL;
    sampler->fs = engineSampleRate > 0 ? engineSampleRate : 44100;
    for (int pad = 0; pad < PADS; pad++) {
        sampler->gain[pad] = 1;
        sampler->rate[pad] = 1;
    }
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
    return crate_sampler_trigger_at(sampler, pad, 0, 0, 1);
}

bool crate_sampler_trigger_at(CrateSampler *sampler, int32_t pad, int64_t atFrame, double position, double rate) {
    return isPad(pad) && send(sampler, (SamplerCommand){.type = SamplerTrigger, .pad = pad, .atFrame = atFrame, .a = position, .b = rate});
}

bool crate_sampler_set_rate(CrateSampler *sampler, int32_t pad, double rate) {
    return isPad(pad) && send(sampler, (SamplerCommand){.type = SamplerRate, .pad = pad, .a = rate});
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
    for (;;) {
        uint32_t before = atomic_load_explicit(&sampler->sequence, memory_order_acquire);
        if (before & 1) continue;
        *out = sampler->published;
        if (atomic_load_explicit(&sampler->sequence, memory_order_acquire) == before) return;
    }
}

static void letGo(CrateSampler *sampler, int pad) {
    for (int v = 0; v < VOICES_PER_PAD; v++) {
        if (sampler->voices[pad][v].active) sampler->voices[pad][v].releasing = true;
    }
}

// Starts a pad sounding from `position` (source frames) at `rate`. `late` is how many frames ago
// it was meant to start: a loop begins that much further on, so it is where it would have been.
static void start(CrateSampler *sampler, int pad, double position, double rate, int64_t late) {
    const PadAudio audio = sampler->audio[pad];
    if (!audio.left) return;
    letGo(sampler, pad);
    if (rate > 0) sampler->rate[pad] = rate;
    // A loop that starts late starts further in. A one-shot starts at its top all the same: better whole and late.
    if (late > 0 && sampler->loops[pad]) position += (double)late * audio.sampleRate / sampler->fs * sampler->rate[pad];
    if (position < 0) position = 0;
    if (position >= (double)audio.frames) {
        if (!sampler->loops[pad]) return;  // it would be over already
        position = fmod(position, (double)audio.frames);
    }
    // The voice that is free, or failing that the quieter of the two.
    Voice *voice = &sampler->voices[pad][0];
    for (int v = 0; v < VOICES_PER_PAD; v++) {
        Voice *candidate = &sampler->voices[pad][v];
        if (!candidate->active) { voice = candidate; break; }
        if (candidate->level < voice->level) voice = candidate;
    }
    // From the top there is no fade in: a drum's attack is in the first few samples.
    // Part-way through, the sound is already going, and cutting into it would click.
    bool within = position > 0;
    *voice = (Voice){.audio = audio, .position = position, .level = within ? 0 : 1, .active = true, .releasing = false, .rising = within};
}

static void apply(CrateSampler *sampler, const SamplerCommand *command) {
    int pad = command->pad;
    switch (command->type) {
    case SamplerAudio:
        // What is sounding fades out of the old audio, which its owner keeps a moment longer for that.
        letGo(sampler, pad);
        sampler->waiting[pad] = false;
        sampler->audio[pad] = sampler->slots[pad][command->slot];
        break;
    case SamplerTrigger:
        if (command->atFrame > sampler->frame) {
            sampler->waiting[pad] = sampler->audio[pad].left != NULL;
            sampler->waitFrame[pad] = command->atFrame;
            sampler->waitPosition[pad] = command->a;
            sampler->waitRate[pad] = command->b;
        } else {
            sampler->waiting[pad] = false;
            start(sampler, pad, command->a, command->b, command->atFrame > 0 ? sampler->frame - command->atFrame : 0);
        }
        break;
    case SamplerStop:
        for (int each = 0; each < PADS; each++) {
            if (pad >= 0 && each != pad) continue;
            letGo(sampler, each);
            sampler->waiting[each] = false;
        }
        break;
    case SamplerPad:
        sampler->gain[pad] = (float)fmax(0, command->a);
        sampler->loops[pad] = command->b != 0;
        break;
    case SamplerRate:
        if (command->a > 0) sampler->rate[pad] = command->a;
        break;
    }
}

// Adds `frames` of every sounding voice to the buffers.
static void sound(CrateSampler *sampler, float *left, float *right, int32_t frames) {
    for (int pad = 0; pad < PADS; pad++) {
        for (int v = 0; v < VOICES_PER_PAD; v++) {
            Voice *voice = &sampler->voices[pad][v];
            if (!voice->active) continue;
            const PadAudio audio = voice->audio;
            const float gain = sampler->gain[pad];
            const bool loops = sampler->loops[pad] && !voice->releasing;
            const double step = audio.sampleRate / sampler->fs * sampler->rate[pad];
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
                voice->position += step;
                if (voice->releasing) {
                    voice->level -= sampler->release;
                    if (voice->level <= 0) { voice->active = false; break; }
                } else if (voice->rising) {
                    voice->level += sampler->release;
                    if (voice->level >= 1) {
                        voice->level = 1;
                        voice->rising = false;
                    }
                }
            }
        }
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

    // In stretches that end where a waiting hit is due, so it starts on its frame exactly.
    int32_t done = 0;
    while (done < frames) {
        int32_t stretch = frames - done;
        for (int pad = 0; pad < PADS; pad++) {
            if (!sampler->waiting[pad]) continue;
            int64_t until = sampler->waitFrame[pad] - sampler->frame;
            if (until <= 0) {
                sampler->waiting[pad] = false;
                start(sampler, pad, sampler->waitPosition[pad], sampler->waitRate[pad], -until);
            } else if (until < stretch) {
                stretch = (int32_t)until;
            }
        }
        sound(sampler, left + done, right + done, stretch);
        done += stretch;
        sampler->frame += stretch;
    }

    uint32_t sequence = atomic_load_explicit(&sampler->sequence, memory_order_relaxed);
    atomic_store_explicit(&sampler->sequence, sequence + 1, memory_order_release);
    sampler->published.frame = sampler->frame;
    for (int pad = 0; pad < PADS; pad++) {
        // A pad is its newest voice: the one not being faded out.
        const Voice *leading = NULL;
        for (int v = 0; v < VOICES_PER_PAD; v++) {
            const Voice *voice = &sampler->voices[pad][v];
            if (voice->active && !voice->releasing) leading = voice;
        }
        float through = leading && leading->audio.frames > 0 ? (float)(leading->position / (double)leading->audio.frames) : 0;
        sampler->published.playing[pad] = leading != NULL || sampler->waiting[pad];
        sampler->published.sounding[pad] = leading != NULL;
        sampler->published.progress[pad] = through > 1 ? 1 : through;
        sampler->published.position[pad] = leading ? leading->position : 0;
    }
    atomic_store_explicit(&sampler->sequence, sequence + 2, memory_order_release);

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
