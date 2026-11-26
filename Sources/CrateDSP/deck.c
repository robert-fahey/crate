#include "CrateDSP.h"

#include <math.h>
#include <stdatomic.h>
#include <stdlib.h>
#include <string.h>

#define QUEUE_SIZE 1024  // commands waiting to cross to the audio thread; a power of two
#define PENDING_MAX 256  // commands scheduled for a later frame
#define AUDIO_SLOTS 8
#define CROSSFADE 64     // frames blended across a jump (seek, loop) so it does not click
#define LOW_CROSSOVER 250.0
#define HIGH_CROSSOVER 2500.0
#define ECHO_SECONDS 2.5
#define CLICK_SLOTS 8
#define CLICK_SECONDS 0.03

// One set of metronome beats. Slots are reused in turn, so the audio thread is never
// reading the one being rewritten unless it has fallen eight updates behind.
typedef struct {
    double *positions;
    uint8_t *accents;
    int32_t count, capacity;
} ClickSlot;

typedef struct {
    const float *left, *right;
    int64_t frames;
    double sampleRate;
    uint64_t generation;
} AudioSlot;

typedef struct {
    double current, target, step;
    int64_t remaining;
} Param;

// A second-order filter section with state for two channels.
typedef struct {
    double b0, b1, b2, a1, a2;
    double z1[2], z2[2];
} Biquad;

struct CrateDeck {
    double fs;

    // Control thread to audio thread.
    CrateCommand queue[QUEUE_SIZE];
    _Atomic uint32_t queueRead, queueWrite;
    AudioSlot slots[AUDIO_SLOTS];
    int nextSlot;  // control thread only
    ClickSlot clickSlots[CLICK_SLOTS];
    int nextClickSlot;  // control thread only
    _Atomic double scratchTarget;

    // Audio thread to control thread, guarded by a sequence counter.
    _Atomic uint32_t sequence;
    CrateDeckSnapshot published;

    // Audio thread only from here down.
    AudioSlot audio;
    double ratio;  // source frames per engine frame at speed 1
    CrateCommand pending[PENDING_MAX];
    int pendingCount;
    Param params[CrateParamCount];
    int64_t frame;
    double position;
    double motor, motorTarget, motorStep;
    bool scratching;
    double scratchVelocity;
    double lastStep;
    bool loopOn;
    double loopStart, loopEnd;
    int64_t loopWraps;
    double travel;
    double fadePosition, fadeStep;  // the old place, still sounding while a jump crossfades
    int fadeLeft;
    double gate;
    bool ended;
    float peak;
    // The loudest sample before the fader since the meter was last read, as the bits of a float.
    // Bits and not a float so that it can be raised and taken atomically; a level is never negative,
    // so its bits are in the same order as its value.
    _Atomic uint32_t meter;

    Biquad lowLP[2], lowHP[2], highLP[2], highHP[2];  // two sections each: 24 dB an octave
    double svf1[2], svf2[2];
    double svfA1, svfA2, svfA3, svfK, filterShaped;
    int filterCountdown;

    const double *clicks;  // metronome beats in use
    const uint8_t *clickAccents;
    int32_t clickCount, clickNext;
    double clickAge;       // frames since the last click started; large when silent
    double clickPitch;

    float *echoLeft, *echoRight;
    int echoSize, echoWrite;
    double echoDamp[2];
    int echoFade;       // > 0 while the tail is being faded out before a clear
    int64_t tailFrames; // how much longer the echo may still be sounding
};

// MARK: Filters

static void butterworth(Biquad *filter, double frequency, double fs, bool highPass) {
    double w = 2.0 * M_PI * frequency / fs;
    double cosw = cos(w), alpha = sin(w) / (2.0 * M_SQRT1_2);
    double a0 = 1.0 + alpha;
    if (highPass) {
        filter->b0 = (1.0 + cosw) / 2.0 / a0;
        filter->b1 = -(1.0 + cosw) / a0;
        filter->b2 = filter->b0;
    } else {
        filter->b0 = (1.0 - cosw) / 2.0 / a0;
        filter->b1 = (1.0 - cosw) / a0;
        filter->b2 = filter->b0;
    }
    filter->a1 = -2.0 * cosw / a0;
    filter->a2 = (1.0 - alpha) / a0;
}

static inline double section(Biquad *filter, int channel, double x) {
    double y = filter->b0 * x + filter->z1[channel];
    filter->z1[channel] = filter->b1 * x - filter->a1 * y + filter->z2[channel];
    filter->z2[channel] = filter->b2 * x - filter->a2 * y;
    return y;
}

// The filter knob: left of centre closes a low-pass, right of centre closes a high-pass.
static void tuneFilter(CrateDeck *deck, double value) {
    double amount = fabs(value);
    double frequency = value < 0 ? 20000.0 * pow(80.0 / 20000.0, amount) : 20.0 * pow(8000.0 / 20.0, amount);
    if (frequency > deck->fs * 0.45) frequency = deck->fs * 0.45;
    double g = tan(M_PI * frequency / deck->fs);
    deck->svfK = 1.0 / 1.1;  // a little resonance
    deck->svfA1 = 1.0 / (1.0 + g * (g + deck->svfK));
    deck->svfA2 = g * deck->svfA1;
    deck->svfA3 = g * deck->svfA2;
    deck->filterShaped = value;
}

// MARK: Lifecycle

CrateDeck *crate_deck_create(double engineSampleRate) {
    CrateDeck *deck = calloc(1, sizeof(CrateDeck));
    if (!deck) return NULL;
    deck->fs = engineSampleRate;
    deck->ratio = 1.0;
    deck->echoSize = (int)(ECHO_SECONDS * engineSampleRate) + 1;
    deck->echoLeft = calloc((size_t)deck->echoSize, sizeof(float));
    deck->echoRight = calloc((size_t)deck->echoSize, sizeof(float));
    for (int i = 0; i < 2; i++) {
        butterworth(&deck->lowLP[i], LOW_CROSSOVER, engineSampleRate, false);
        butterworth(&deck->lowHP[i], LOW_CROSSOVER, engineSampleRate, true);
        butterworth(&deck->highLP[i], HIGH_CROSSOVER, engineSampleRate, false);
        butterworth(&deck->highHP[i], HIGH_CROSSOVER, engineSampleRate, true);
    }
    static const double defaults[CrateParamCount] = {
        [CrateParamTempo] = 1, [CrateParamGain] = 1, [CrateParamTrim] = 1, [CrateParamEQLow] = 1, [CrateParamEQMid] = 1,
        [CrateParamEQHigh] = 1, [CrateParamDry] = 1, [CrateParamEchoFeedback] = 0.5, [CrateParamEchoLevel] = 1,
    };
    for (int i = 0; i < CrateParamCount; i++) deck->params[i].current = deck->params[i].target = defaults[i];
    deck->params[CrateParamEchoFrames].current = deck->params[CrateParamEchoFrames].target = engineSampleRate * 0.375;
    tuneFilter(deck, 0);
    deck->clickAge = 1e9;
    return deck;
}

void crate_deck_destroy(CrateDeck *deck) {
    if (!deck) return;
    free(deck->echoLeft);
    free(deck->echoRight);
    for (int i = 0; i < CLICK_SLOTS; i++) {
        free(deck->clickSlots[i].positions);
        free(deck->clickSlots[i].accents);
    }
    free(deck);
}

// MARK: Control side

bool crate_deck_send(CrateDeck *deck, CrateCommand command) {
    uint32_t write = atomic_load_explicit(&deck->queueWrite, memory_order_relaxed);
    uint32_t read = atomic_load_explicit(&deck->queueRead, memory_order_acquire);
    if (write - read >= QUEUE_SIZE) return false;
    deck->queue[write & (QUEUE_SIZE - 1)] = command;
    atomic_store_explicit(&deck->queueWrite, write + 1, memory_order_release);
    return true;
}

bool crate_deck_set_audio(CrateDeck *deck, const float *left, const float *right, int64_t frames,
                          double sampleRate, uint64_t generation) {
    int slot = deck->nextSlot;
    deck->nextSlot = (slot + 1) % AUDIO_SLOTS;
    deck->slots[slot] = (AudioSlot){left, right, frames, sampleRate, generation};
    return crate_deck_send(deck, (CrateCommand){.type = CrateCmdAudio, .param = slot});
}

bool crate_deck_set_clicks(CrateDeck *deck, const double *positions, const uint8_t *accents, int32_t count) {
    int index = deck->nextClickSlot;
    deck->nextClickSlot = (index + 1) % CLICK_SLOTS;
    ClickSlot *slot = &deck->clickSlots[index];
    if (count > slot->capacity) {
        free(slot->positions);
        free(slot->accents);
        slot->positions = malloc((size_t)count * sizeof(double));
        slot->accents = malloc((size_t)count * sizeof(uint8_t));
        slot->capacity = slot->positions && slot->accents ? count : 0;
        if (!slot->capacity) return false;
    }
    if (count > 0) {
        memcpy(slot->positions, positions, (size_t)count * sizeof(double));
        memcpy(slot->accents, accents, (size_t)count * sizeof(uint8_t));
    }
    slot->count = count;
    return crate_deck_send(deck, (CrateCommand){.type = CrateCmdClicks, .param = index});
}

void crate_deck_set_scratch_target(CrateDeck *deck, double position) {
    atomic_store_explicit(&deck->scratchTarget, position, memory_order_relaxed);
}

float crate_deck_take_level(CrateDeck *deck) {
    uint32_t bits = atomic_exchange_explicit(&deck->meter, 0, memory_order_relaxed);
    float level;
    memcpy(&level, &bits, sizeof level);
    return level;
}

void crate_deck_snapshot(CrateDeck *deck, CrateDeckSnapshot *out) {
    for (;;) {
        uint32_t before = atomic_load_explicit(&deck->sequence, memory_order_acquire);
        if (before & 1) continue;
        *out = deck->published;
        if (atomic_load_explicit(&deck->sequence, memory_order_acquire) == before) return;
    }
}

// MARK: Audio thread

static void jump(CrateDeck *deck, double position) {
    deck->fadePosition = deck->position;
    deck->fadeStep = deck->lastStep;
    deck->fadeLeft = CROSSFADE;
    deck->position = position;
}

static void apply(CrateDeck *deck, const CrateCommand *command) {
    switch (command->type) {
    case CrateCmdAudio:
        if (command->param >= 0 && command->param < AUDIO_SLOTS) {
            deck->audio = deck->slots[command->param];
            deck->ratio = deck->audio.sampleRate > 0 ? deck->audio.sampleRate / deck->fs : 1.0;
            deck->position = 0;
            deck->travel = 0;
            deck->motor = deck->motorTarget = deck->motorStep = 0;
            deck->scratching = false;
            deck->loopOn = false;
            deck->loopWraps = 0;
            deck->fadeLeft = 0;
            deck->ended = false;
            deck->pendingCount = 0;  // anything scheduled was for the previous track
        }
        break;
    case CrateCmdSeek:
        jump(deck, command->a);
        deck->loopWraps = 0;
        deck->ended = false;
        break;
    case CrateCmdMotor:
        // With no ramp the platter is at speed on the very next frame, so a kick
        // sitting on the cue point keeps its attack; the gate alone stops the click.
        deck->motorTarget = command->a;
        if (command->b > 0) {
            deck->motorStep = (deck->motorTarget - deck->motor) / (command->b * deck->fs);
        } else {
            deck->motor = deck->motorTarget;
        }
        if (command->a != 0) deck->ended = false;
        break;
    case CrateCmdLoop:
        deck->loopStart = command->a;
        deck->loopEnd = command->b;
        deck->loopOn = command->b > command->a + 1;
        deck->loopWraps = 0;
        break;
    case CrateCmdLoopOff:
        deck->loopOn = false;
        deck->loopWraps = 0;
        break;
    case CrateCmdRamp:
        if (command->param >= 0 && command->param < CrateParamCount) {
            Param *param = &deck->params[command->param];
            int64_t frames = command->b > 0 ? (int64_t)command->b : (int64_t)(0.012 * deck->fs);
            if (command->param == CrateParamEchoFrames) frames = 1;  // gliding the echo time bends its pitch
            // A glide is there to keep a change from clicking. A deck that is making no sound has
            // nothing to click, and gliding would have it start from the old value: a volume turned
            // down before the first track is played must already be down when that track starts.
            if (deck->motor == 0 && deck->motorTarget == 0 && !deck->scratching && deck->gate <= 1e-5 && deck->tailFrames <= 0) {
                frames = 1;
            }
            if (frames < 1) frames = 1;
            param->target = command->a;
            param->remaining = frames;
            param->step = (param->target - param->current) / (double)frames;
        }
        break;
    case CrateCmdScratch:
        if (command->a != 0) {
            deck->scratching = true;
            deck->scratchVelocity = deck->lastStep;
            deck->ended = false;
        } else if (deck->scratching) {
            deck->scratching = false;
            // The platter carries on at the speed the hand left it and settles to the motor's speed.
            double base = (deck->params[CrateParamTempo].current + deck->params[CrateParamBend].current) * deck->ratio;
            double speed = fabs(base) > 1e-9 ? deck->scratchVelocity / base : 0;
            deck->motor = fmax(-8.0, fmin(8.0, speed));
            deck->motorStep = (deck->motorTarget - deck->motor) / (fmax(command->b, 0.004) * deck->fs);
        }
        break;
    case CrateCmdEchoClear:
        deck->echoFade = 128;
        break;
    case CrateCmdClicks:
        if (command->param >= 0 && command->param < CLICK_SLOTS) {
            const ClickSlot *slot = &deck->clickSlots[command->param];
            deck->clicks = slot->positions;
            deck->clickAccents = slot->accents;
            deck->clickCount = slot->count;
            deck->clickNext = -1;  // find our place again
        }
        break;
    }
}

static void schedule(CrateDeck *deck, const CrateCommand *command) {
    if (deck->pendingCount >= PENDING_MAX) {  // full: better early than never
        apply(deck, command);
        return;
    }
    int index = deck->pendingCount;
    while (index > 0 && deck->pending[index - 1].atFrame > command->atFrame) {
        deck->pending[index] = deck->pending[index - 1];
        index--;
    }
    deck->pending[index] = *command;
    deck->pendingCount++;
}

/// Drops a start that is still waiting for its frame: the jump to the beat and the motor command with it.
static void cancelWaitingStart(CrateDeck *deck) {
    int kept = 0;
    for (int i = 0; i < deck->pendingCount; i++) {
        int32_t type = deck->pending[i].type;
        if (type != CrateCmdMotor && type != CrateCmdSeek) deck->pending[kept++] = deck->pending[i];
    }
    deck->pendingCount = kept;
}

static inline double sampleAt(const float *data, int64_t frames, int64_t index) {
    return index >= 0 && index < frames ? (double)data[index] : 0.0;
}

// Reads the track at a fractional position with a four-point cubic.
static inline void readSource(const AudioSlot *audio, double position, double *left, double *right) {
    if (!audio->left || position < -2 || position > (double)audio->frames + 1) {
        *left = *right = 0;
        return;
    }
    double whole = floor(position);
    int64_t index = (int64_t)whole;
    double t = position - whole;
    double l[4], r[4];
    if (index >= 1 && index < audio->frames - 2) {
        for (int k = 0; k < 4; k++) {
            l[k] = audio->left[index - 1 + k];
            r[k] = audio->right[index - 1 + k];
        }
    } else {
        for (int k = 0; k < 4; k++) {
            l[k] = sampleAt(audio->left, audio->frames, index - 1 + k);
            r[k] = sampleAt(audio->right, audio->frames, index - 1 + k);
        }
    }
    if (t == 0) {
        *left = l[1];
        *right = r[1];
        return;
    }
    *left = ((((0.5 * (l[3] - l[0]) + 1.5 * (l[1] - l[2])) * t + (l[0] - 2.5 * l[1] + 2.0 * l[2] - 0.5 * l[3])) * t
              + 0.5 * (l[2] - l[0])) * t) + l[1];
    *right = ((((0.5 * (r[3] - r[0]) + 1.5 * (r[1] - r[2])) * t + (r[0] - 2.5 * r[1] + 2.0 * r[2] - 0.5 * r[3])) * t
               + 0.5 * (r[2] - r[0])) * t) + r[1];
}

static void process(CrateDeck *deck, float *outLeft, float *outRight, float *phonesLeft, float *phonesRight, int count) {
    Param *params = deck->params;
    const double followRate = 1.0 / (0.022 * deck->fs);  // the scratch catches the hand in about 22 ms
    const double velocitySmoothing = 1.0 - exp(-1.0 / (0.006 * deck->fs));
    const double gateOpen = 1.0 - exp(-1.0 / (0.00015 * deck->fs));  // open within a few samples
    const double gateClose = 1.0 - exp(-1.0 / (0.0015 * deck->fs));
    const double dampRate = 1.0 - exp(-2.0 * M_PI * 5000.0 / deck->fs);
    float loudest = 0;

    for (int i = 0; i < count; i++) {
        for (int p = 0; p < CrateParamCount; p++) {
            if (params[p].remaining > 0) {
                params[p].current += params[p].step;
                if (--params[p].remaining == 0) params[p].current = params[p].target;
            }
        }
        if (deck->motor != deck->motorTarget) {
            deck->motor += deck->motorStep;
            if ((deck->motorStep >= 0 && deck->motor >= deck->motorTarget)
                || (deck->motorStep < 0 && deck->motor <= deck->motorTarget)) {
                deck->motor = deck->motorTarget;
            }
        }

        // How far the record moves this frame.
        double step;
        if (deck->scratching) {
            double target = atomic_load_explicit(&deck->scratchTarget, memory_order_relaxed);
            double wanted = (target - deck->position) * followRate;
            double limit = 12.0 * deck->ratio;
            wanted = fmax(-limit, fmin(limit, wanted));
            deck->scratchVelocity += (wanted - deck->scratchVelocity) * velocitySmoothing;
            step = deck->scratchVelocity;
        } else {
            step = deck->motor * (params[CrateParamTempo].current + params[CrateParamBend].current) * deck->ratio;
        }
        deck->lastStep = step;

        double left = 0, right = 0;
        bool moving = fabs(step) > 1e-5 * deck->ratio;
        deck->gate += moving ? (1.0 - deck->gate) * gateOpen : -deck->gate * gateClose;
        if (deck->gate > 1e-5 && !deck->ended) {
            readSource(&deck->audio, deck->position, &left, &right);
            if (deck->fadeLeft > 0) {
                double oldLeft, oldRight;
                readSource(&deck->audio, deck->fadePosition, &oldLeft, &oldRight);
                double mix = (double)deck->fadeLeft / (double)CROSSFADE;
                left = left * (1.0 - mix) + oldLeft * mix;
                right = right * (1.0 - mix) + oldRight * mix;
                deck->fadePosition += deck->fadeStep;
                deck->fadeLeft--;
            }
            left *= deck->gate;
            right *= deck->gate;
        } else if (deck->fadeLeft > 0) {
            deck->fadeLeft = 0;
        }

        // Metronome: a click as the playhead passes each beat, going forwards.
        if (deck->clickCount > 0 && params[CrateParamClick].current > 0) {
            double before = deck->position, after = deck->position + step;
            int32_t next = deck->clickNext;
            if (next < 0 || next > deck->clickCount || (next > 0 && deck->clicks[next - 1] > before)
                || (next < deck->clickCount && deck->clicks[next] < before - 2.0 * fabs(step) - 1.0)) {
                // Lost our place (a seek, a loop, a new grid): find the first beat at or after here.
                int32_t low = 0, high = deck->clickCount;
                while (low < high) {
                    int32_t middle = (low + high) / 2;
                    if (deck->clicks[middle] < before) low = middle + 1; else high = middle;
                }
                next = low;
            }
            if (step > 0 && next < deck->clickCount && deck->clicks[next] < after) {
                deck->clickAge = 0;
                deck->clickPitch = deck->clickAccents[next] ? 1760.0 : 1100.0;
                next++;
            }
            deck->clickNext = next;
        }

        deck->position += step;
        deck->travel += step;
        if (deck->loopOn && !deck->scratching) {
            // Counted, so that whoever draws the deck can tell a trip round the loop from a jump.
            double length = deck->loopEnd - deck->loopStart;
            if (step > 0 && deck->position >= deck->loopEnd) {
                deck->loopWraps += (int64_t)floor((deck->position - deck->loopStart) / length);
                jump(deck, deck->loopStart + fmod(deck->position - deck->loopStart, length));
                deck->fadePosition = deck->position + length;  // keep sounding what was just past the end
            } else if (step < 0 && deck->position < deck->loopStart) {
                double past = fmod(deck->loopStart - deck->position, length);
                deck->loopWraps -= (int64_t)floor((deck->loopStart - deck->position) / length) + 1;
                jump(deck, deck->loopEnd - past);
                deck->fadePosition = deck->position - length;
            }
        } else if (deck->loopOn && deck->position < deck->loopStart) {
            deck->loopWraps = 0;  // scratched back out of the loop: what is heard is the track before it
        }
        if (deck->position >= (double)deck->audio.frames && step > 0) {
            deck->position = (double)deck->audio.frames;
            if (!deck->scratching && deck->audio.left) deck->ended = true;
        } else if (deck->position < 0 && step < 0) {
            deck->position = 0;
            if (!deck->scratching && deck->motorTarget < 0) deck->motor = deck->motorTarget = 0;  // rewound to the start
        }

        // Three-band isolator.
        double channels[2] = {left + 1e-20, right + 1e-20};
        double lowGain = params[CrateParamEQLow].current, midGain = params[CrateParamEQMid].current;
        double highGain = params[CrateParamEQHigh].current;
        for (int c = 0; c < 2; c++) {
            double x = channels[c];
            double low = section(&deck->lowLP[1], c, section(&deck->lowLP[0], c, x));
            double rest = section(&deck->lowHP[1], c, section(&deck->lowHP[0], c, x));
            double mid = section(&deck->highLP[1], c, section(&deck->highLP[0], c, rest));
            double high = section(&deck->highHP[1], c, section(&deck->highHP[0], c, rest));
            channels[c] = low * lowGain + mid * midGain + high * highGain;
        }

        // Filter knob.
        double knob = params[CrateParamFilter].current;
        if (knob != deck->filterShaped && --deck->filterCountdown <= 0) {
            tuneFilter(deck, knob);
            deck->filterCountdown = 16;
        }
        double filterMix = fmin(1.0, fabs(knob) / 0.04);
        if (filterMix > 0) {
            for (int c = 0; c < 2; c++) {
                double x = channels[c];
                double v3 = x - deck->svf2[c];
                double v1 = deck->svfA1 * deck->svf1[c] + deck->svfA2 * v3;
                double v2 = deck->svf2[c] + deck->svfA2 * deck->svf1[c] + deck->svfA3 * v3;
                deck->svf1[c] = 2.0 * v1 - deck->svf1[c];
                deck->svf2[c] = 2.0 * v2 - deck->svf2[c];
                double shaped = knob < 0 ? v2 : x - deck->svfK * v1 - v2;
                channels[c] = x * (1.0 - filterMix) + shaped * filterMix;
            }
        }

        // Echo.
        double send = params[CrateParamEchoSend].current;
        if (send > 1e-4) deck->tailFrames = (int64_t)(deck->fs * 20.0);
        double echoed[2] = {0, 0};
        if (deck->tailFrames > 0) {
            deck->tailFrames--;
            int delay = (int)params[CrateParamEchoFrames].current;
            if (delay < 1) delay = 1;
            if (delay >= deck->echoSize) delay = deck->echoSize - 1;
            int readIndex = deck->echoWrite - delay;
            if (readIndex < 0) readIndex += deck->echoSize;
            double tail[2] = {deck->echoLeft[readIndex], deck->echoRight[readIndex]};
            double feedback = fmin(0.95, fmax(0.0, params[CrateParamEchoFeedback].current));
            for (int c = 0; c < 2; c++) {
                deck->echoDamp[c] += (tail[c] - deck->echoDamp[c]) * dampRate;  // each repeat a little duller
                echoed[c] = tail[c] * params[CrateParamEchoLevel].current;
            }
            if (deck->echoFade > 0) {
                double fade = (double)deck->echoFade / 128.0;
                echoed[0] *= fade;
                echoed[1] *= fade;
                if (--deck->echoFade == 0) {
                    memset(deck->echoLeft, 0, (size_t)deck->echoSize * sizeof(float));
                    memset(deck->echoRight, 0, (size_t)deck->echoSize * sizeof(float));
                    deck->echoDamp[0] = deck->echoDamp[1] = 0;
                    deck->tailFrames = send > 1e-4 ? (int64_t)(deck->fs * 20.0) : 0;
                }
            } else {
                deck->echoLeft[deck->echoWrite] = (float)(channels[0] * send + deck->echoDamp[0] * feedback);
                deck->echoRight[deck->echoWrite] = (float)(channels[1] * send + deck->echoDamp[1] * feedback);
            }
            if (++deck->echoWrite >= deck->echoSize) deck->echoWrite = 0;
        } else {
            deck->echoFade = 0;
        }

        // The metronome is for the DJ, not the dancefloor's EQ: it bypasses the deck's tone and fader.
        double click = 0;
        if (deck->clickAge < CLICK_SECONDS * deck->fs) {
            double t = deck->clickAge / deck->fs;
            click = sin(2.0 * M_PI * deck->clickPitch * t) * exp(-t * 220.0) * 0.5 * params[CrateParamClick].current;
            deck->clickAge += 1;
        }

        double gain = params[CrateParamGain].current, dry = params[CrateParamDry].current;
        double trim = params[CrateParamTrim].current;
        // The deck as it stands before its fader: what the headphone cue listens to.
        double before[2] = {(channels[0] * dry + echoed[0]) * trim, (channels[1] * dry + echoed[1]) * trim};
        float l = (float)(before[0] * gain + click);
        float r = (float)(before[1] * gain + click);
        outLeft[i] = l;
        outRight[i] = r;
        if (phonesLeft) {
            // Cue: before the fader. Monitor: as in the mix. Rendered together with the master,
            // so the two outputs stay in step to the sample.
            double share = params[CrateParamCue].current + gain * params[CrateParamMonitor].current;
            phonesLeft[i] = (float)(before[0] * share + click);
            phonesRight[i] = (float)(before[1] * share + click);
        }
        float level = fabsf(l) > fabsf(r) ? fabsf(l) : fabsf(r);
        if (level > deck->peak) deck->peak = level;
        float pre = (float)(fabs(before[0]) > fabs(before[1]) ? fabs(before[0]) : fabs(before[1]));
        if (pre > loudest) loudest = pre;
    }
    if (loudest > 0) {
        uint32_t bits;
        memcpy(&bits, &loudest, sizeof bits);
        uint32_t held = atomic_load_explicit(&deck->meter, memory_order_relaxed);
        while (bits > held && !atomic_compare_exchange_weak_explicit(&deck->meter, &held, bits, memory_order_relaxed, memory_order_relaxed)) {}
    }
}

// MARK: Clock

struct CrateClock {
    _Atomic int64_t frames;
};

CrateClock *crate_clock_create(void) { return calloc(1, sizeof(CrateClock)); }
void crate_clock_destroy(CrateClock *clock) { free(clock); }
void crate_clock_advance(CrateClock *clock, int32_t frames) {
    atomic_fetch_add_explicit(&clock->frames, frames, memory_order_relaxed);
}
int64_t crate_clock_frames(CrateClock *clock) { return atomic_load_explicit(&clock->frames, memory_order_relaxed); }

void crate_deck_render(CrateDeck *deck, float *left, float *right, float *phonesLeft, float *phonesRight, int32_t frames) {
    uint32_t read = atomic_load_explicit(&deck->queueRead, memory_order_relaxed);
    uint32_t write = atomic_load_explicit(&deck->queueWrite, memory_order_acquire);
    while (read != write) {
        const CrateCommand *command = &deck->queue[read & (QUEUE_SIZE - 1)];
        if (command->atFrame <= deck->frame) {
            // Stopping or starting the deck now overrules a start that was waiting for the master's beat.
            // Otherwise a deck stopped in that moment (Cue tapped and let go) would start by itself.
            if (command->type == CrateCmdMotor) cancelWaitingStart(deck);
            apply(deck, command);
        } else {
            schedule(deck, command);
        }
        read++;
    }
    atomic_store_explicit(&deck->queueRead, read, memory_order_release);

    deck->peak = 0;
    int done = 0;
    while (done < frames) {
        while (deck->pendingCount > 0 && deck->pending[0].atFrame <= deck->frame) {
            CrateCommand command = deck->pending[0];
            deck->pendingCount--;
            memmove(&deck->pending[0], &deck->pending[1], (size_t)deck->pendingCount * sizeof(CrateCommand));
            apply(deck, &command);
        }
        int segment = frames - done;
        if (deck->pendingCount > 0) {
            int64_t until = deck->pending[0].atFrame - deck->frame;
            if (until < segment) segment = (int)until;
        }
        process(deck, left + done, right + done, phonesLeft ? phonesLeft + done : NULL, phonesRight ? phonesRight + done : NULL, segment);
        done += segment;
        deck->frame += segment;
    }

    uint32_t sequence = atomic_load_explicit(&deck->sequence, memory_order_relaxed);
    atomic_store_explicit(&deck->sequence, sequence + 1, memory_order_release);
    deck->published = (CrateDeckSnapshot){
        .position = deck->position,
        .speed = deck->ratio > 0 ? deck->lastStep / deck->ratio : 0,
        .frame = deck->frame,
        .audioGeneration = deck->audio.generation,
        .loopStart = deck->loopStart,
        .loopEnd = deck->loopEnd,
        .travel = deck->travel,
        .loopWraps = deck->loopOn ? deck->loopWraps : 0,
        .peak = deck->peak,
        .playing = deck->motorTarget != 0,
        .ended = deck->ended,
        .looping = deck->loopOn,
        .scratching = deck->scratching,
    };
    atomic_store_explicit(&deck->sequence, sequence + 2, memory_order_release);
}
