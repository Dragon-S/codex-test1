#pragma once

#include <stdbool.h>
#include <stddef.h>

typedef struct MPVProbe MPVProbe;
typedef void (*MPVProbeRenderCallback)(void *context);

MPVProbe *mpv_probe_create(const char *path, char *error, size_t error_size);
void mpv_probe_set_render_callback(
    MPVProbe *probe,
    MPVProbeRenderCallback callback,
    void *context
);
void mpv_probe_destroy(MPVProbe *probe);

int mpv_probe_render(
    MPVProbe *probe,
    void *pixels,
    int width,
    int height,
    size_t stride
);
void mpv_probe_poll_events(MPVProbe *probe);

double mpv_probe_time(MPVProbe *probe);
double mpv_probe_duration(MPVProbe *probe);
int mpv_probe_video_width(MPVProbe *probe);
int mpv_probe_video_height(MPVProbe *probe);
bool mpv_probe_is_paused(MPVProbe *probe);
void mpv_probe_set_paused(MPVProbe *probe, bool paused);
void mpv_probe_seek_relative(MPVProbe *probe, double seconds);
void mpv_probe_copy_property(
    MPVProbe *probe,
    const char *name,
    char *output,
    size_t output_size
);
