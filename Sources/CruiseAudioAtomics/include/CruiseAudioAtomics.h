#ifndef CRUISE_AUDIO_ATOMICS_H
#define CRUISE_AUDIO_ATOMICS_H

#include <stdbool.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct CruiseAudioRenderState CruiseAudioRenderState;

CruiseAudioRenderState *CruiseAudioRenderStateCreate(float gain);
void CruiseAudioRenderStateDestroy(CruiseAudioRenderState *state);
float CruiseAudioRenderStateGetGain(const CruiseAudioRenderState *state);
void CruiseAudioRenderStateSetGain(CruiseAudioRenderState *state, float gain);
bool CruiseAudioRenderStateHasReceivedAudio(const CruiseAudioRenderState *state);
void CruiseAudioRenderStateSetReceivedAudio(CruiseAudioRenderState *state);

#ifdef __cplusplus
}
#endif

#endif
