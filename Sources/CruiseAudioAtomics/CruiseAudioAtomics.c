#include "CruiseAudioAtomics.h"

#include <stdatomic.h>
#include <stdlib.h>

struct CruiseAudioRenderState {
    _Atomic(float) gain;
    _Atomic(bool) receivedAudio;
};

CruiseAudioRenderState *CruiseAudioRenderStateCreate(float gain) {
    CruiseAudioRenderState *state = malloc(sizeof(*state));
    if (state == NULL) return NULL;
    atomic_init(&state->gain, gain);
    atomic_init(&state->receivedAudio, false);
    return state;
}

void CruiseAudioRenderStateDestroy(CruiseAudioRenderState *state) {
    free(state);
}

float CruiseAudioRenderStateGetGain(const CruiseAudioRenderState *state) {
    return atomic_load_explicit(&state->gain, memory_order_relaxed);
}

void CruiseAudioRenderStateSetGain(CruiseAudioRenderState *state, float gain) {
    atomic_store_explicit(&state->gain, gain, memory_order_relaxed);
}

bool CruiseAudioRenderStateHasReceivedAudio(const CruiseAudioRenderState *state) {
    return atomic_load_explicit(&state->receivedAudio, memory_order_relaxed);
}

void CruiseAudioRenderStateSetReceivedAudio(CruiseAudioRenderState *state) {
    atomic_store_explicit(&state->receivedAudio, true, memory_order_relaxed);
}
