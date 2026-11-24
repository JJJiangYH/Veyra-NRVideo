// SPDX-License-Identifier: GPL-3.0-only
#include <obs-module.h>
#include <util/platform.h>
#include "../../include/veyra/obs/FrameBus.h"

#include <fcntl.h>
#include <pthread.h>
#include <stdatomic.h>
#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <sys/file.h>
#include <sys/stat.h>
#include <unistd.h>

struct veyra_obs_source {
    obs_source_t *source;
    char *path;
    pthread_t thread;
    atomic_bool stop;
    bool running;
};

static const char *source_name(void *opaque)
{
    UNUSED_PARAMETER(opaque);
    return "Veyra Processed Video";
}

static void *receive_frames(void *opaque)
{
    struct veyra_obs_source *ctx = opaque;
    uint8_t *data = NULL;
    size_t capacity = 0;
    uint64_t sequence = 0, epoch = 0;
    while (!atomic_load(&ctx->stop)) {
        int fd = open(ctx->path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC);
        if (fd >= 0) {
            if (flock(fd, LOCK_SH | LOCK_NB) == 0) {
                struct stat file;
                struct veyra_obs_header header;
                if (fstat(fd, &file) == 0 && S_ISREG(file.st_mode) && file.st_uid == getuid() &&
                    (file.st_mode & 077) == 0 &&
                    pread(fd, &header, sizeof(header), 0) == sizeof(header) &&
                    header.magic == VEYRA_OBS_MAGIC && header.version == VEYRA_OBS_VERSION &&
                    header.width > 0 && header.width <= VEYRA_OBS_MAX_WIDTH &&
                    header.height > 0 && header.height <= VEYRA_OBS_MAX_HEIGHT &&
                    header.stride >= header.width * 4 && header.stride <= VEYRA_OBS_MAX_WIDTH * 4 + 1024 &&
                    (header.sequence != sequence || header.epoch != epoch)) {
                    size_t length = (size_t)header.stride * header.height;
                    if (length > capacity) {
                        void *expanded = realloc(data, length);
                        if (expanded) {
                            data = expanded;
                            capacity = length;
                        }
                    }
                    bool ready = length <= capacity &&
                        pread(fd, data, length, sizeof(header)) == (ssize_t)length;
                    flock(fd, LOCK_UN);
                    close(fd);
                    fd = -1;
                    if (ready) {
                        struct obs_source_frame frame = {0};
                        frame.format = VIDEO_FORMAT_BGRA;
                        frame.width = header.width;
                        frame.height = header.height;
                        frame.linesize[0] = header.stride;
                        frame.data[0] = data;
                        frame.full_range = true;
                        frame.timestamp = os_gettime_ns();
                        obs_source_output_video(ctx->source, &frame);
                        epoch = header.epoch;
                        sequence = header.sequence;
                    }
                }
            }
            if (fd >= 0) close(fd);
        }
        os_sleep_ms(8);
    }
    free(data);
    return NULL;
}

static void *source_create(obs_data_t *settings, obs_source_t *source)
{
    const char *configured_path = obs_data_get_string(settings, "frame_path");
    const char *home = getenv("HOME");
    if (!home) return NULL;
    const char *suffix = "/Library/Caches/" VEYRA_OBS_FOLDER "/" VEYRA_OBS_FILE;
    const size_t length = strlen(home) + strlen(suffix) + 1;
    struct veyra_obs_source *context = bzalloc(sizeof(*context));
    context->path = bmalloc(length);
    snprintf(context->path, length, "%s%s", home, suffix);
    if (configured_path && configured_path[0] == '/') {
        bfree(context->path);
        context->path = bstrdup(configured_path);
    }
    context->source = source;
    atomic_init(&context->stop, false);
    return context;
}

static void source_activate(void *data)
{
    struct veyra_obs_source *context = data;
    if (!context->running) {
        atomic_store(&context->stop, false);
        context->running = pthread_create(&context->thread, NULL, receive_frames, context) == 0;
    }
}

static void source_deactivate(void *data)
{
    struct veyra_obs_source *context = data;
    if (context->running) {
        atomic_store(&context->stop, true);
        pthread_join(context->thread, NULL);
        context->running = false;
    }
    obs_source_output_video(context->source, NULL);
}

static void source_destroy(void *data)
{
    struct veyra_obs_source *context = data;
    source_deactivate(context);
    bfree(context->path);
    bfree(context);
}

struct obs_source_info veyra_processed_video = {
    .id = "veyra_processed_video",
    .type = OBS_SOURCE_TYPE_INPUT,
    .output_flags = OBS_SOURCE_ASYNC_VIDEO,
    .get_name = source_name,
    .create = source_create,
    .destroy = source_destroy,
    .activate = source_activate,
    .deactivate = source_deactivate,
};
