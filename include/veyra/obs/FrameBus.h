// SPDX-License-Identifier: GPL-3.0-only
#ifndef VEYRA_OBS_FRAME_H
#define VEYRA_OBS_FRAME_H

#include <stdint.h>

#define VEYRA_OBS_MAGIC UINT64_C(0x56455952414F4253)
#define VEYRA_OBS_VERSION 1
#define VEYRA_OBS_MAX_WIDTH 4096u
#define VEYRA_OBS_MAX_HEIGHT 4096u
#define VEYRA_OBS_FOLDER "Veyra OBS"
#define VEYRA_OBS_FILE "frame.bgra"

struct veyra_obs_header {
    uint64_t magic;
    uint64_t epoch;
    uint64_t sequence;
    uint32_t version;
    uint32_t width;
    uint32_t height;
    uint32_t stride;
};

#endif
