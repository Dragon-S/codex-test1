#include "MPVProbeBridge.h"

#include <mpv/client.h>
#include <mpv/render.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

struct MPVProbe {
    mpv_handle *handle;
    mpv_render_context *render_context;
    MPVProbeRenderCallback render_callback;
    void *render_callback_context;
};

static void copy_error(char *output, size_t output_size, const char *message) {
    if (!output || output_size == 0) {
        return;
    }
    snprintf(output, output_size, "%s", message);
}

static void on_render_update(void *context) {
    MPVProbe *probe = context;
    if (probe->render_callback) {
        probe->render_callback(probe->render_callback_context);
    }
}

MPVProbe *mpv_probe_create(const char *path, char *error, size_t error_size) {
    MPVProbe *probe = calloc(1, sizeof(*probe));
    if (!probe) {
        copy_error(error, error_size, "无法分配 MPVProbe");
        return NULL;
    }

    probe->handle = mpv_create();
    if (!probe->handle) {
        copy_error(error, error_size, "mpv_create 失败");
        free(probe);
        return NULL;
    }

    mpv_set_option_string(probe->handle, "vo", "libmpv");
    mpv_set_option_string(probe->handle, "terminal", "no");
    mpv_set_option_string(probe->handle, "keep-open", "yes");
    mpv_set_option_string(probe->handle, "audio-display", "no");
    mpv_set_option_string(probe->handle, "profile", "sw-fast");
    mpv_set_option_string(probe->handle, "slang", "zho,zh,chi");
    mpv_set_option_string(probe->handle, "sid", "auto");

    int status = mpv_initialize(probe->handle);
    if (status < 0) {
        copy_error(error, error_size, mpv_error_string(status));
        mpv_terminate_destroy(probe->handle);
        free(probe);
        return NULL;
    }

    char *api = MPV_RENDER_API_TYPE_SW;
    mpv_render_param params[] = {
        {MPV_RENDER_PARAM_API_TYPE, api},
        {MPV_RENDER_PARAM_INVALID, NULL},
    };
    status = mpv_render_context_create(
        &probe->render_context,
        probe->handle,
        params
    );
    if (status < 0) {
        copy_error(error, error_size, mpv_error_string(status));
        mpv_terminate_destroy(probe->handle);
        free(probe);
        return NULL;
    }

    mpv_render_context_set_update_callback(
        probe->render_context,
        on_render_update,
        probe
    );

    const char *command[] = {"loadfile", path, NULL};
    status = mpv_command(probe->handle, command);
    if (status < 0) {
        copy_error(error, error_size, mpv_error_string(status));
        mpv_render_context_free(probe->render_context);
        mpv_terminate_destroy(probe->handle);
        free(probe);
        return NULL;
    }

    return probe;
}

void mpv_probe_set_render_callback(
    MPVProbe *probe,
    MPVProbeRenderCallback callback,
    void *context
) {
    if (!probe) {
        return;
    }
    probe->render_callback_context = context;
    probe->render_callback = callback;
}

void mpv_probe_destroy(MPVProbe *probe) {
    if (!probe) {
        return;
    }
    probe->render_callback = NULL;
    probe->render_callback_context = NULL;
    mpv_render_context_set_update_callback(
        probe->render_context,
        NULL,
        NULL
    );
    mpv_render_context_free(probe->render_context);
    mpv_terminate_destroy(probe->handle);
    free(probe);
}

int mpv_probe_render(
    MPVProbe *probe,
    void *pixels,
    int width,
    int height,
    size_t stride
) {
    if (!probe || !pixels || width <= 0 || height <= 0) {
        return MPV_ERROR_INVALID_PARAMETER;
    }

    int size[] = {width, height};
    int block_for_target_time = 0;
    char *format = "bgr0";
    mpv_render_param params[] = {
        {MPV_RENDER_PARAM_SW_SIZE, size},
        {MPV_RENDER_PARAM_SW_FORMAT, format},
        {MPV_RENDER_PARAM_SW_STRIDE, &stride},
        {MPV_RENDER_PARAM_SW_POINTER, pixels},
        {
            MPV_RENDER_PARAM_BLOCK_FOR_TARGET_TIME,
            &block_for_target_time
        },
        {MPV_RENDER_PARAM_INVALID, NULL},
    };
    return mpv_render_context_render(probe->render_context, params);
}

void mpv_probe_poll_events(MPVProbe *probe) {
    if (!probe) {
        return;
    }
    while (mpv_wait_event(probe->handle, 0)->event_id != MPV_EVENT_NONE) {
    }
}

static double double_property(MPVProbe *probe, const char *name) {
    double value = 0;
    if (!probe ||
        mpv_get_property(
            probe->handle,
            name,
            MPV_FORMAT_DOUBLE,
            &value
        ) < 0) {
        return 0;
    }
    return value;
}

static int int_property(MPVProbe *probe, const char *name) {
    int64_t value = 0;
    if (!probe ||
        mpv_get_property(
            probe->handle,
            name,
            MPV_FORMAT_INT64,
            &value
        ) < 0) {
        return 0;
    }
    return (int)value;
}

double mpv_probe_time(MPVProbe *probe) {
    return double_property(probe, "time-pos");
}

double mpv_probe_duration(MPVProbe *probe) {
    return double_property(probe, "duration");
}

int mpv_probe_video_width(MPVProbe *probe) {
    return int_property(probe, "dwidth");
}

int mpv_probe_video_height(MPVProbe *probe) {
    return int_property(probe, "dheight");
}

bool mpv_probe_is_paused(MPVProbe *probe) {
    int value = 0;
    if (!probe ||
        mpv_get_property(
            probe->handle,
            "pause",
            MPV_FORMAT_FLAG,
            &value
        ) < 0) {
        return true;
    }
    return value != 0;
}

void mpv_probe_set_paused(MPVProbe *probe, bool paused) {
    if (!probe) {
        return;
    }
    int value = paused ? 1 : 0;
    mpv_set_property(
        probe->handle,
        "pause",
        MPV_FORMAT_FLAG,
        &value
    );
}

void mpv_probe_seek_relative(MPVProbe *probe, double seconds) {
    if (!probe) {
        return;
    }
    char amount[64];
    snprintf(amount, sizeof(amount), "%.6f", seconds);
    const char *command[] = {"seek", amount, "relative+exact", NULL};
    mpv_command_async(probe->handle, 0, command);
}

void mpv_probe_copy_property(
    MPVProbe *probe,
    const char *name,
    char *output,
    size_t output_size
) {
    if (!output || output_size == 0) {
        return;
    }
    output[0] = '\0';
    if (!probe) {
        return;
    }
    char *value = mpv_get_property_string(probe->handle, name);
    if (!value) {
        return;
    }
    snprintf(output, output_size, "%s", value);
    mpv_free(value);
}
