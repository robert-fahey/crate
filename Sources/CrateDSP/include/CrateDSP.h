// The audio core of one deck. Everything that runs on the audio thread lives
// here, in C, so it never allocates, locks or touches the Swift runtime.
//
// One thread (the audio thread) calls crate_deck_render. One other thread at a
// time may call the control functions; the Swift wrapper serialises them.
#ifndef CRATE_DSP_H
#define CRATE_DSP_H

#include <stdbool.h>
#include <stdint.h>

typedef struct CrateDeck CrateDeck;

// Continuous controls. Each moves smoothly to a new value (see CrateCmdRamp).
typedef enum {
    CrateParamTempo = 0,     // playback speed, 1 = as recorded
    CrateParamBend,          // added to the tempo while nudging
    CrateParamGain,          // gain after the trim: channel fader x crossfader x master
    CrateParamEQLow,         // band gains, linear; 0 kills the band
    CrateParamEQMid,
    CrateParamEQHigh,
    CrateParamFilter,        // -1...0 low-pass closing, 0 off, 0...1 high-pass closing
    CrateParamDry,           // level of the deck itself after the filter (0 for an echo-out)
    CrateParamEchoSend,      // how much of the deck feeds the echo
    CrateParamEchoFeedback,  // 0...0.95
    CrateParamEchoLevel,     // level of the echo in the output
    CrateParamEchoFrames,    // echo time, in engine frames (not smoothed)
    CrateParamClick,         // metronome level, 0 off
    CrateParamTrim,          // gain before the fader; what the headphone cue hears includes it
    CrateParamCue,           // how much of the deck as it is before the fader goes to the headphones
    CrateParamMonitor,       // how much of the deck as it is in the master mix goes to the headphones
    CrateParamCount
} CrateParam;

typedef enum {
    CrateCmdAudio = 0,   // start using the audio in slot `param`; resets position, motor and loop
    CrateCmdSeek,        // a = position in source frames
    CrateCmdMotor,       // a = target speed (1 play, 0 stop, negative runs backwards), b = seconds to get there (0: at once)
    CrateCmdLoop,        // a = start, b = end, in source frames
    CrateCmdLoopOff,
    CrateCmdRamp,        // param moves to a over b engine frames (b <= 0: the default short glide; b = 1: at once)
    CrateCmdScratch,     // a != 0: follow the scratch target; a == 0: let go, reaching motor speed over b seconds
    CrateCmdEchoClear,   // silence the echo tail
    CrateCmdClicks       // start using the metronome beats in slot `param`
} CrateCommandType;

typedef struct {
    int32_t type;
    int32_t param;
    int64_t atFrame;     // apply when the deck has rendered this many frames; 0 = straight away
    double a;
    double b;
} CrateCommand;

typedef struct {
    double position;         // source frames, as of `frame`
    double speed;            // current speed including motor and scratch, 1 = as recorded
    int64_t frame;           // engine frames this deck has rendered
    uint64_t audioGeneration;
    double loopStart, loopEnd;
    float peak;              // loudest output sample in the last render
    bool playing;            // the motor is on or heading there
    bool ended;              // played off the end of the track
    bool looping;
    bool scratching;
} CrateDeckSnapshot;

CrateDeck *crate_deck_create(double engineSampleRate);
void crate_deck_destroy(CrateDeck *deck);

// Control side. Returns false if the command queue is full.
bool crate_deck_send(CrateDeck *deck, CrateCommand command);
// Hands the deck new audio. The memory must stay valid until a snapshot reports a
// later generation, or the deck is destroyed. `right` may equal `left` for mono.
bool crate_deck_set_audio(CrateDeck *deck, const float *left, const float *right, int64_t frames,
                          double sampleRate, uint64_t generation);
// Gives the deck the beats for its metronome: positions in source frames, ascending,
// with `accents[i]` non-zero for the first beat of a bar. The deck copies them. It clicks
// as the playhead passes each one, so the click follows any tempo. Level is CrateParamClick.
bool crate_deck_set_clicks(CrateDeck *deck, const double *positions, const uint8_t *accents, int32_t count);
// Where the hand is holding the record while scratching, in source frames.
void crate_deck_set_scratch_target(CrateDeck *deck, double position);
void crate_deck_snapshot(CrateDeck *deck, CrateDeckSnapshot *out);

// Audio thread. `left` and `right` are the deck's part of the master mix. `phonesLeft` and
// `phonesRight`, if not NULL, get its part of what the headphones hear: the deck before its
// fader (the cue) and the deck as it is in the mix, each at its own level.
void crate_deck_render(CrateDeck *deck, float *left, float *right, float *phonesLeft, float *phonesRight, int32_t frames);

// Counts the frames the output has actually been given. A deck behind a unit
// that buffers (key lock) is rendered ahead of this; the difference is its lead.
typedef struct CrateClock CrateClock;
CrateClock *crate_clock_create(void);
void crate_clock_destroy(CrateClock *clock);
void crate_clock_advance(CrateClock *clock, int32_t frames);  // audio thread
int64_t crate_clock_frames(CrateClock *clock);


// MARK: Sampler
//
// Eight pads, each holding a short piece of audio that plays from its start when
// the pad is hit. A pad hit again starts again; what was sounding fades out in a
// few milliseconds rather than being cut. A pad can loop. The sampler has its own
// level into the master mix and its own way to the headphones, like a deck.

#define CRATE_SAMPLER_PADS 8

typedef struct CrateSampler CrateSampler;

typedef struct {
    bool playing[CRATE_SAMPLER_PADS];
    float progress[CRATE_SAMPLER_PADS];  // how far through its audio each pad is, 0...1
} CrateSamplerSnapshot;

CrateSampler *crate_sampler_create(double engineSampleRate);
void crate_sampler_destroy(CrateSampler *sampler);

// From one control thread at a time. Each returns false if the queue is full.
// The audio is not copied: it must stay where it is for as long as the pad has it, and for
// a moment after it is replaced (the sound in flight fades out of the old memory).
bool crate_sampler_set_audio(CrateSampler *sampler, int32_t pad, const float *left, const float *right, int64_t frames, double sampleRate);
bool crate_sampler_trigger(CrateSampler *sampler, int32_t pad);
bool crate_sampler_stop(CrateSampler *sampler, int32_t pad);  // pad < 0: every pad
bool crate_sampler_set_pad(CrateSampler *sampler, int32_t pad, double gain, bool loops);
// master: level into the mix. cue: level to the headphones whatever the master level is.
// monitor: how much of what goes to the mix the headphones hear as well.
void crate_sampler_set_levels(CrateSampler *sampler, double master, double cue, double monitor);
void crate_sampler_snapshot(CrateSampler *sampler, CrateSamplerSnapshot *out);

// Audio thread. Writes `frames` samples to each buffer; the headphone pair may be NULL.
void crate_sampler_render(CrateSampler *sampler, float *left, float *right, float *phonesLeft, float *phonesRight, int32_t frames);

#endif
