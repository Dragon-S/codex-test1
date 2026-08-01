#define GL_SILENCE_DEPRECATION
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
#import "MPVClient.h"
#import <mpv/client.h>
#import <mpv/render_gl.h>
#import <dlfcn.h>

static void *MPVGetOpenGLProcAddress(void *context, const char *name) {
    return dlsym(RTLD_DEFAULT, name);
}

static void MPVRenderUpdate(void *context);

@interface MPVClient () {
    mpv_handle *_handle;
    dispatch_queue_t _queue;
    dispatch_source_t _eventTimer;
    BOOL _hasLoadedFile;
    BOOL _isReplacingFile;
    mpv_render_context *_renderContext;
    __weak NSOpenGLView *_videoView;
}
@end

@implementation MPVClient

- (instancetype)initWithVideoView:(NSView *)videoView {
    self = [super init];
    if (self == nil) {
        return nil;
    }

    if (![videoView isKindOfClass:NSOpenGLView.class]) {
        return self;
    }
    _queue = dispatch_queue_create("com.dragon-s.MacMediaPlayer.libmpv", DISPATCH_QUEUE_SERIAL);
    _videoView = (NSOpenGLView *)videoView;
    _handle = mpv_create();
    if (_handle == NULL) {
        return self;
    }

    mpv_set_option_string(_handle, "config", "no");
    mpv_set_option_string(_handle, "terminal", "no");
    mpv_set_option_string(_handle, "hwdec", "videotoolbox");
    mpv_set_option_string(_handle, "keep-open", "yes");
    mpv_set_option_string(_handle, "vo", "libmpv");

    int result = mpv_initialize(_handle);
    if (result < 0) {
        mpv_terminate_destroy(_handle);
        _handle = NULL;
        return self;
    }

    if (![self createRenderContext]) {
        mpv_terminate_destroy(_handle);
        _handle = NULL;
        return self;
    }

    mpv_observe_property(_handle, 0, "pause", MPV_FORMAT_FLAG);
    [self startEventTimer];
    _videoView.postsFrameChangedNotifications = YES;
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(videoViewFrameDidChange:)
                                                 name:NSViewFrameDidChangeNotification
                                               object:_videoView];
    return self;
}

- (void)dealloc {
    [self shutdown];
}

- (void)loadURL:(NSURL *)url {
    NSString *path = url.path;
    [self performCommand:@[ @"loadfile", path, @"replace" ] loading:YES];
    [self performCommand:@[ @"set", @"pause", @"no" ] loading:NO];
}

- (void)play {
    [self performCommand:@[ @"set", @"pause", @"no" ] loading:NO];
}

- (void)pause {
    [self performCommand:@[ @"set", @"pause", @"yes" ] loading:NO];
}

- (void)stop {
    [self performCommand:@[ @"stop" ] loading:NO];
}

- (void)shutdown {
    if (_handle == NULL && _eventTimer == nil) {
        return;
    }
    [[NSNotificationCenter defaultCenter] removeObserver:self];
    if (_renderContext != NULL) {
        mpv_render_context_set_update_callback(_renderContext, NULL, NULL);
        mpv_render_context_free(_renderContext);
        _renderContext = NULL;
    }
    dispatch_sync(_queue, ^{
        if (self->_eventTimer != nil) {
            dispatch_source_set_event_handler(self->_eventTimer, ^{});
            dispatch_source_cancel(self->_eventTimer);
            self->_eventTimer = nil;
        }
        if (self->_handle != NULL) {
            mpv_terminate_destroy(self->_handle);
            self->_handle = NULL;
        }
    });
}

- (BOOL)createRenderContext {
    NSOpenGLContext *openGLContext = _videoView.openGLContext;
    if (openGLContext == nil) {
        return NO;
    }
    [openGLContext makeCurrentContext];

    mpv_opengl_init_params openGLParameters = {
        .get_proc_address = MPVGetOpenGLProcAddress,
        .get_proc_address_ctx = NULL,
    };
    mpv_render_param parameters[] = {
        { MPV_RENDER_PARAM_API_TYPE, (void *)MPV_RENDER_API_TYPE_OPENGL },
        { MPV_RENDER_PARAM_OPENGL_INIT_PARAMS, &openGLParameters },
        { MPV_RENDER_PARAM_INVALID, NULL },
    };
    int result = mpv_render_context_create(&_renderContext, _handle, parameters);
    if (result < 0) {
        _renderContext = NULL;
        return NO;
    }
    mpv_render_context_set_update_callback(_renderContext, MPVRenderUpdate, (__bridge void *)self);
    return YES;
}

- (void)videoViewFrameDidChange:(NSNotification *)notification {
    [self renderFrame];
}

- (void)renderFrame {
    NSOpenGLView *videoView = _videoView;
    if (_renderContext == NULL || videoView == nil) {
        return;
    }

    NSOpenGLContext *openGLContext = videoView.openGLContext;
    [openGLContext makeCurrentContext];
    [openGLContext update];
    mpv_render_context_update(_renderContext);
    NSSize backingSize = [videoView convertSizeToBacking:videoView.bounds.size];
    mpv_opengl_fbo framebuffer = {
        .fbo = 0,
        .w = (int)backingSize.width,
        .h = (int)backingSize.height,
        .internal_format = 0,
    };
    int flipY = 1;
    mpv_render_param parameters[] = {
        { MPV_RENDER_PARAM_OPENGL_FBO, &framebuffer },
        { MPV_RENDER_PARAM_FLIP_Y, &flipY },
        { MPV_RENDER_PARAM_INVALID, NULL },
    };
    mpv_render_context_render(_renderContext, parameters);
    [openGLContext flushBuffer];
    mpv_render_context_report_swap(_renderContext);
}

- (void)performCommand:(NSArray<NSString *> *)arguments loading:(BOOL)loading {
    dispatch_async(_queue, ^{
        if (self->_handle == NULL) {
            [self reportFailure:MPVClientFailureEngineUnavailable];
            return;
        }

        const char *command[arguments.count + 1];
        for (NSUInteger index = 0; index < arguments.count; index++) {
            command[index] = arguments[index].UTF8String;
        }
        command[arguments.count] = NULL;

        int result = mpv_command(self->_handle, command);
        if (result < 0) {
            [self reportFailure:[self failureForError:result]];
        } else if (loading) {
            self->_hasLoadedFile = NO;
            self->_isReplacingFile = YES;
            [self reportState:MPVClientPlaybackStateLoading];
        }
    });
}

- (void)startEventTimer {
    _eventTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, _queue);
    dispatch_source_set_timer(_eventTimer, DISPATCH_TIME_NOW, 10 * NSEC_PER_MSEC, 2 * NSEC_PER_MSEC);
    dispatch_source_set_event_handler(_eventTimer, ^{
        [self drainEvents];
    });
    dispatch_resume(_eventTimer);
}

- (void)drainEvents {
    while (_handle != NULL) {
        mpv_event *event = mpv_wait_event(_handle, 0);
        if (event->event_id == MPV_EVENT_NONE) {
            return;
        }

        switch (event->event_id) {
            case MPV_EVENT_FILE_LOADED:
                _hasLoadedFile = YES;
                _isReplacingFile = NO;
                [self reportCurrentPauseState];
                break;
            case MPV_EVENT_PROPERTY_CHANGE:
                [self handlePropertyChange:event];
                break;
            case MPV_EVENT_END_FILE:
                [self handleEndFile:event];
                break;
            case MPV_EVENT_SHUTDOWN:
                [self reportState:MPVClientPlaybackStateStopped];
                break;
            default:
                break;
        }
    }
}

- (void)handlePropertyChange:(mpv_event *)event {
    if (!_hasLoadedFile) {
        return;
    }
    mpv_event_property *property = event->data;
    if (property == NULL || strcmp(property->name, "pause") != 0 ||
        property->format != MPV_FORMAT_FLAG || property->data == NULL) {
        return;
    }

    int paused = *(int *)property->data;
    [self reportState:paused ? MPVClientPlaybackStatePaused : MPVClientPlaybackStatePlaying];
}

- (void)handleEndFile:(mpv_event *)event {
    mpv_event_end_file *endFile = event->data;
    if (_isReplacingFile && endFile != NULL && endFile->reason == MPV_END_FILE_REASON_STOP) {
        return;
    }
    _hasLoadedFile = NO;
    _isReplacingFile = NO;
    if (endFile != NULL && endFile->reason == MPV_END_FILE_REASON_ERROR) {
        [self reportFailure:[self failureForError:endFile->error]];
    } else {
        [self reportState:MPVClientPlaybackStateStopped];
    }
}

- (void)reportCurrentPauseState {
    int paused = 0;
    if (mpv_get_property(_handle, "pause", MPV_FORMAT_FLAG, &paused) < 0) {
        return;
    }
    [self reportState:paused ? MPVClientPlaybackStatePaused : MPVClientPlaybackStatePlaying];
}

- (MPVClientFailure)failureForError:(int)error {
    switch (error) {
        case MPV_ERROR_LOADING_FAILED:
        case MPV_ERROR_NOTHING_TO_PLAY:
            return MPVClientFailureUnreadable;
        case MPV_ERROR_UNKNOWN_FORMAT:
        case MPV_ERROR_UNSUPPORTED:
            return MPVClientFailureUnsupported;
        case MPV_ERROR_AO_INIT_FAILED:
        case MPV_ERROR_VO_INIT_FAILED:
            return MPVClientFailureDecoderInitialization;
        default:
            return MPVClientFailureCorrupted;
    }
}

- (void)reportState:(MPVClientPlaybackState)state {
    if (self.stateHandler != nil) {
        self.stateHandler(state);
    }
}

- (void)reportFailure:(MPVClientFailure)failure {
    if (self.failureHandler != nil) {
        self.failureHandler(failure);
    }
}

@end

static void MPVRenderUpdate(void *context) {
    MPVClient *client = (__bridge MPVClient *)context;
    dispatch_async(dispatch_get_main_queue(), ^{
        [client renderFrame];
    });
}

#pragma clang diagnostic pop
