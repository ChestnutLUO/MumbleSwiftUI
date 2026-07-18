#include "include/opus_shim.h"

int mumble_opus_encoder_set_bitrate(OpusEncoder *st, opus_int32 bitsPerSecond) {
    return opus_encoder_ctl(st, OPUS_SET_BITRATE(bitsPerSecond));
}

int mumble_opus_encoder_get_bitrate(OpusEncoder *st, opus_int32 *bitsPerSecond) {
    return opus_encoder_ctl(st, OPUS_GET_BITRATE(bitsPerSecond));
}

int mumble_opus_encoder_set_vbr(OpusEncoder *st, int enabled) {
    return opus_encoder_ctl(st, OPUS_SET_VBR(enabled));
}

int mumble_opus_encoder_set_signal_voice(OpusEncoder *st) {
    return opus_encoder_ctl(st, OPUS_SET_SIGNAL(OPUS_SIGNAL_VOICE));
}

int mumble_opus_encoder_set_inband_fec(OpusEncoder *st, int enabled) {
    return opus_encoder_ctl(st, OPUS_SET_INBAND_FEC(enabled));
}

int mumble_opus_encoder_set_packet_loss_perc(OpusEncoder *st, int percent) {
    return opus_encoder_ctl(st, OPUS_SET_PACKET_LOSS_PERC(percent));
}

int mumble_opus_encoder_reset(OpusEncoder *st) {
    return opus_encoder_ctl(st, OPUS_RESET_STATE);
}

int mumble_opus_decoder_reset(OpusDecoder *st) {
    return opus_decoder_ctl(st, OPUS_RESET_STATE);
}
