// Non-variadic wrappers around opus_*_ctl so Swift can call them
// (Swift cannot call C variadic functions).
#ifndef MUMBLE_OPUS_SHIM_H
#define MUMBLE_OPUS_SHIM_H

#include <opus.h>

int mumble_opus_encoder_set_bitrate(OpusEncoder *st, opus_int32 bitsPerSecond);
int mumble_opus_encoder_get_bitrate(OpusEncoder *st, opus_int32 *bitsPerSecond);
int mumble_opus_encoder_set_vbr(OpusEncoder *st, int enabled);
int mumble_opus_encoder_set_signal_voice(OpusEncoder *st);
int mumble_opus_encoder_set_inband_fec(OpusEncoder *st, int enabled);
int mumble_opus_encoder_set_packet_loss_perc(OpusEncoder *st, int percent);
int mumble_opus_encoder_reset(OpusEncoder *st);
int mumble_opus_decoder_reset(OpusDecoder *st);

#endif
