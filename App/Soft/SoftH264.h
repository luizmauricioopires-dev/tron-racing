// Codificador H.264 em software (OpenH264), usado quando o iPhone está bloqueado e o iOS
// não deixa usar o chip de vídeo.
#ifndef SOFT_H264_H
#define SOFT_H264_H
#include <stdint.h>

typedef struct SoftH264 SoftH264;

SoftH264 *sh264_create(int width, int height, float fps, int bitrate);
/// Codifica uma imagem BGRA (32 bits). Escreve Annex-B em `out` (quadros-chave já com SPS/PPS).
/// Devolve bytes escritos, 0 se o quadro foi pulado, ou negativo em erro.
int sh264_encode_bgra(SoftH264 *e, const uint8_t *bgra, int stride, int force_idr,
                      uint8_t *out, int out_capacity, int *is_key);
void sh264_destroy(SoftH264 *e);

#endif
