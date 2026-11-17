#include "SoftH264.h"
#include <stdlib.h>
#include <string.h>
#include "wels/codec_api.h"

struct SoftH264 {
    ISVCEncoder *enc;
    int w, h;
    float fps;
    uint8_t *y, *u, *v;
    long long ts;
};

SoftH264 *sh264_create(int w, int h, float fps, int bitrate) {
    if (w <= 0 || h <= 0 || (w & 1) || (h & 1)) return NULL;
    SoftH264 *s = calloc(1, sizeof(SoftH264));
    if (!s) return NULL;
    if (WelsCreateSVCEncoder(&s->enc) != 0 || !s->enc) { free(s); return NULL; }
    // Parâmetros explícitos para um vídeo bem simples, igual ao do chip de vídeo (que o painel
    // decodifica liso): perfil Baseline, 1 fatia, 1 quadro de referência, sem recursos extras.
    SEncParamExt p;
    memset(&p, 0, sizeof(p));
    (*s->enc)->GetDefaultParams(s->enc, &p);
    p.iUsageType = CAMERA_VIDEO_REAL_TIME;
    p.fMaxFrameRate = fps;
    p.iPicWidth = w;
    p.iPicHeight = h;
    p.iTargetBitrate = bitrate;
    p.iMaxBitrate = bitrate * 2;
    p.iRCMode = RC_BITRATE_MODE;
    p.bEnableFrameSkip = false;
    p.iSpatialLayerNum = 1;
    p.iTemporalLayerNum = 1;
    p.iNumRefFrame = 1;
    p.bEnableLongTermReference = false;
    p.iEntropyCodingModeFlag = 0;
    p.iMultipleThreadIdc = 1;
    p.bEnableSceneChangeDetect = false;
    p.bEnableBackgroundDetection = false;
    p.bEnableAdaptiveQuant = false;
    p.bEnableDenoise = false;
    p.bPrefixNalAddingCtrl = false;
    p.eSpsPpsIdStrategy = CONSTANT_ID;
    p.uiIntraPeriod = (unsigned int)(fps * 2);
    p.iComplexityMode = LOW_COMPLEXITY;
    p.sSpatialLayers[0].iVideoWidth = w;
    p.sSpatialLayers[0].iVideoHeight = h;
    p.sSpatialLayers[0].fFrameRate = fps;
    p.sSpatialLayers[0].iSpatialBitrate = bitrate;
    p.sSpatialLayers[0].iMaxSpatialBitrate = bitrate * 2;
    p.sSpatialLayers[0].uiProfileIdc = PRO_BASELINE;
    p.sSpatialLayers[0].sSliceArgument.uiSliceMode = SM_SINGLE_SLICE;
    if ((*s->enc)->InitializeExt(s->enc, &p) != 0) {
        WelsDestroySVCEncoder(s->enc);
        free(s);
        return NULL;
    }
    int quiet = WELS_LOG_QUIET;
    (*s->enc)->SetOption(s->enc, ENCODER_OPTION_TRACE_LEVEL, &quiet);
    int fmt = videoFormatI420;
    (*s->enc)->SetOption(s->enc, ENCODER_OPTION_DATAFORMAT, &fmt);
    int idr = (int)(fps * 2); // quadro-chave a cada ~2 s
    (*s->enc)->SetOption(s->enc, ENCODER_OPTION_IDR_INTERVAL, &idr);
    s->w = w; s->h = h; s->fps = fps;
    s->y = malloc((size_t)w * h);
    s->u = malloc((size_t)w * h / 4);
    s->v = malloc((size_t)w * h / 4);
    if (!s->y || !s->u || !s->v) { sh264_destroy(s); return NULL; }
    return s;
}

// BGRA -> I420 (BT.601, faixa limitada), média de 2x2 para a cor
static void to_i420(SoftH264 *s, const uint8_t *bgra, int stride) {
    const int w = s->w, h = s->h;
    for (int j = 0; j < h; j++) {
        const uint8_t *row = bgra + (size_t)j * stride;
        uint8_t *yr = s->y + (size_t)j * w;
        for (int i = 0; i < w; i++) {
            int b = row[i * 4], g = row[i * 4 + 1], r = row[i * 4 + 2];
            yr[i] = (uint8_t)(((66 * r + 129 * g + 25 * b + 128) >> 8) + 16);
        }
    }
    for (int j = 0; j < h / 2; j++) {
        const uint8_t *r0 = bgra + (size_t)(2 * j) * stride;
        const uint8_t *r1 = r0 + stride;
        for (int i = 0; i < w / 2; i++) {
            const uint8_t *a = r0 + i * 8, *b = r1 + i * 8;
            int B = (a[0] + a[4] + b[0] + b[4]) >> 2;
            int G = (a[1] + a[5] + b[1] + b[5]) >> 2;
            int R = (a[2] + a[6] + b[2] + b[6]) >> 2;
            s->u[j * (w / 2) + i] = (uint8_t)(((-38 * R - 74 * G + 112 * B + 128) >> 8) + 128);
            s->v[j * (w / 2) + i] = (uint8_t)(((112 * R - 94 * G - 18 * B + 128) >> 8) + 128);
        }
    }
}

int sh264_encode_bgra(SoftH264 *s, const uint8_t *bgra, int stride, int force_idr,
                      uint8_t *out, int cap, int *is_key) {
    if (!s || !bgra || !out) return -1;
    to_i420(s, bgra, stride);
    SSourcePicture pic;
    memset(&pic, 0, sizeof(pic));
    pic.iPicWidth = s->w;
    pic.iPicHeight = s->h;
    pic.iColorFormat = videoFormatI420;
    pic.iStride[0] = s->w;
    pic.iStride[1] = pic.iStride[2] = s->w / 2;
    pic.pData[0] = s->y; pic.pData[1] = s->u; pic.pData[2] = s->v;
    pic.uiTimeStamp = s->ts;
    s->ts += (long long)(1000.0f / s->fps);
    if (force_idr) (*s->enc)->ForceIntraFrame(s->enc, true);
    SFrameBSInfo info;
    memset(&info, 0, sizeof(info));
    if ((*s->enc)->EncodeFrame(s->enc, &pic, &info) != cmResultSuccess) return -2;
    if (info.eFrameType == videoFrameTypeSkip || info.eFrameType == videoFrameTypeInvalid) return 0;
    int total = 0;
    for (int l = 0; l < info.iLayerNum; l++) {
        const SLayerBSInfo *li = &info.sLayerInfo[l];
        int sz = 0;
        for (int n = 0; n < li->iNalCount; n++) sz += li->pNalLengthInByte[n];
        if (total + sz > cap) return -3;
        memcpy(out + total, li->pBsBuf, sz);
        total += sz;
    }
    if (is_key) *is_key = (info.eFrameType == videoFrameTypeIDR) ? 1 : 0;
    return total;
}

void sh264_destroy(SoftH264 *s) {
    if (!s) return;
    if (s->enc) {
        (*s->enc)->Uninitialize(s->enc);
        WelsDestroySVCEncoder(s->enc);
    }
    free(s->y); free(s->u); free(s->v);
    free(s);
}
