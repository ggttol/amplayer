// 对 Monkey's Audio SDK 的薄封装：打开、按 float 读取、跳转、读标签
#include "mp9_ape.h"

#include "All.h"
#include "MACLib.h"
#include "IAPETag.h"
#include "CharacterHelper.h"

#include <cstring>
#include <vector>

using namespace APE;

struct mp9_ape {
    IAPEDecompress *decoder = nullptr;
    int channels = 0;
    int bits = 0;
    int blockAlign = 0;
    bool isFloat = false;
    std::vector<unsigned char> scratch;
};

extern "C" mp9_ape *mp9_ape_open(const char *utf8_path, mp9_ape_info *info, int32_t *error) {
    int code = 0;
    str_utfn *path = CAPECharacterHelper::GetUTFNFromUTF8(reinterpret_cast<const str_utf8 *>(utf8_path));
    IAPEDecompress *decoder = CreateIAPEDecompress(path, &code, true, true, false);
    delete[] path;
    if (!decoder || code != 0) {
        delete decoder;
        if (error) *error = code != 0 ? code : -1;
        return nullptr;
    }
    auto *ape = new mp9_ape();
    ape->decoder = decoder;
    ape->channels = static_cast<int>(decoder->GetInfo(IAPEDecompress::APE_INFO_CHANNELS));
    ape->bits = static_cast<int>(decoder->GetInfo(IAPEDecompress::APE_INFO_BITS_PER_SAMPLE));
    ape->blockAlign = static_cast<int>(decoder->GetInfo(IAPEDecompress::APE_INFO_BLOCK_ALIGN));
    ape->isFloat = (decoder->GetInfo(IAPEDecompress::APE_INFO_FORMAT_FLAGS) & APE_FORMAT_FLAG_FLOATING_POINT) != 0;
    if (info) {
        info->sample_rate = static_cast<int32_t>(decoder->GetInfo(IAPEDecompress::APE_INFO_SAMPLE_RATE));
        info->channels = ape->channels;
        info->bits_per_sample = ape->bits;
        info->is_float = ape->isFloat ? 1 : 0;
        info->total_frames = decoder->GetInfo(IAPEDecompress::APE_DECOMPRESS_TOTAL_BLOCKS);
    }
    if (error) *error = 0;
    return ape;
}

extern "C" int32_t mp9_ape_read_float(mp9_ape *ape, float *const *channels, int32_t max_frames) {
    if (!ape || max_frames <= 0) return 0;
    const size_t need = static_cast<size_t>(max_frames) * static_cast<size_t>(ape->blockAlign);
    if (ape->scratch.size() < need) ape->scratch.resize(need);
    int64 got = 0;
    const int result = ape->decoder->GetData(ape->scratch.data(), max_frames, &got);
    if (result != 0) return -result;
    const unsigned char *p = ape->scratch.data();
    const int bytes = ape->bits / 8;
    for (int64 frame = 0; frame < got; frame++) {
        for (int c = 0; c < ape->channels; c++) {
            float v = 0;
            switch (bytes) {
            case 1: v = (static_cast<int>(p[0]) - 128) / 128.0f; break;
            case 2: v = static_cast<int16_t>(p[0] | (p[1] << 8)) / 32768.0f; break;
            case 3: {
                int32_t s = (p[0] << 8) | (p[1] << 16) | (p[2] << 24);
                v = (s >> 8) / 8388608.0f;
                break;
            }
            case 4:
                if (ape->isFloat) {
                    std::memcpy(&v, p, 4);
                } else {
                    int32_t s;
                    std::memcpy(&s, p, 4);
                    v = static_cast<float>(s / 2147483648.0);
                }
                break;
            default: break;
            }
            channels[c][frame] = v;
            p += bytes;
        }
    }
    return static_cast<int32_t>(got);
}

extern "C" int32_t mp9_ape_seek(mp9_ape *ape, int64_t frame) {
    if (!ape) return -1;
    return ape->decoder->Seek(frame);
}

extern "C" int32_t mp9_ape_tag(mp9_ape *ape, const char *field, char *out, int32_t out_size) {
    if (!ape || !field || !out || out_size <= 1) return -1;
    IAPETag *tag = reinterpret_cast<IAPETag *>(ape->decoder->GetInfo(IAPEDecompress::APE_INFO_TAG));
    if (!tag) return -1;
    str_utfn *name = CAPECharacterHelper::GetUTFNFromUTF8(reinterpret_cast<const str_utf8 *>(field));
    int chars = out_size - 1;
    // bUTF8Encode = true：按 UTF-8 输出
    const int result = tag->GetFieldString(name, reinterpret_cast<str_ansi *>(out), &chars, true);
    delete[] name;
    if (result != 0) return -1;
    out[(chars >= 0 && chars < out_size) ? chars : out_size - 1] = 0;
    return 0;
}

extern "C" void mp9_ape_close(mp9_ape *ape) {
    if (!ape) return;
    delete ape->decoder;
    delete ape;
}

extern "C" int32_t mp9_ape_compress_wav_for_tests(const char *utf8_wav, const char *utf8_ape, int32_t level) {
    str_utfn *input = CAPECharacterHelper::GetUTFNFromUTF8(reinterpret_cast<const str_utf8 *>(utf8_wav));
    str_utfn *output = CAPECharacterHelper::GetUTFNFromUTF8(reinterpret_cast<const str_utf8 *>(utf8_ape));
    const int result = CompressFileW(input, output, level, APE_NULL, 1, APE_NULL, false);
    delete[] input;
    delete[] output;
    return result;
}
