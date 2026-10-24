// Monkey's Audio（APE）解码的最小 C 接口，供 Swift 调用
#ifndef MP9_APE_H
#define MP9_APE_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct mp9_ape mp9_ape;

typedef struct {
    int32_t sample_rate;
    int32_t channels;
    int32_t bits_per_sample;
    int32_t is_float;
    int64_t total_frames;
} mp9_ape_info;

/// 打开 APE 文件（UTF-8 路径）。失败返回 NULL，并写入错误码
mp9_ape *mp9_ape_open(const char *utf8_path, mp9_ape_info *info, int32_t *error);

/// 解码最多 max_frames 帧到各声道的 float 缓冲区（-1...1）。返回实际帧数，0 表示结束，负数为错误
int32_t mp9_ape_read_float(mp9_ape *ape, float *const *channels, int32_t max_frames);

/// 跳到第 frame 帧。成功返回 0
int32_t mp9_ape_seek(mp9_ape *ape, int64_t frame);

/// 读取 APE 标签（如 "Title"、"Artist"、"Album"、"Track"），UTF-8 写入 out。成功返回 0
int32_t mp9_ape_tag(mp9_ape *ape, const char *field, char *out, int32_t out_size);

void mp9_ape_close(mp9_ape *ape);

/// 仅供测试：把 WAV 压缩成 APE（level 1000～5000）。成功返回 0
int32_t mp9_ape_compress_wav_for_tests(const char *utf8_wav, const char *utf8_ape, int32_t level);

#ifdef __cplusplus
}
#endif

#endif
