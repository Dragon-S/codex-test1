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

@implementation MPVClientTrack

- (instancetype)initWithIdentifier:(NSUUID *)identifier
                      languageCode:(NSString *)languageCode
                              title:(NSString *)title
                            ordinal:(NSInteger)ordinal
                          isDefault:(BOOL)isDefault
                            isForced:(BOOL)isForced {
    self = [super init];
    if (self != nil) {
        _identifier = identifier;
        _languageCode = [languageCode copy];
        _title = [title copy];
        _ordinal = ordinal;
        _defaultTrack = isDefault;
        _forced = isForced;
    }
    return self;
}

@end

@interface MPVClient () {
    mpv_handle *_handle;
    dispatch_queue_t _queue;
    dispatch_source_t _eventTimer;
    BOOL _hasLoadedFile;
    uint64_t _requestedLoadID;
    uint64_t _eventLoadID;
    NSMutableArray<NSNumber *> *_pendingLoadIDs;
    NSMutableDictionary<NSNumber *, NSNumber *> *_loadIDsByPlaylistEntryID;
    NSMutableDictionary<NSUUID *, NSNumber *> *_audioTrackIDs;
    NSMutableDictionary<NSUUID *, NSNumber *> *_subtitleTrackIDs;
    NSMutableDictionary<NSNumber *, NSUUID *> *_audioIdentifiers;
    NSMutableDictionary<NSNumber *, NSUUID *> *_subtitleIdentifiers;
    mpv_render_context *_renderContext;
    __weak NSOpenGLView *_videoView;
    double _position;
    double _duration;
    CFAbsoluteTime _lastTimelineReportTime;
    BOOL _forceNextPositionReport;
    double _playbackRate;
    double _playerVolume;
    BOOL _muted;
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
    _pendingLoadIDs = [NSMutableArray array];
    _loadIDsByPlaylistEntryID = [NSMutableDictionary dictionary];
    _audioTrackIDs = [NSMutableDictionary dictionary];
    _subtitleTrackIDs = [NSMutableDictionary dictionary];
    _audioIdentifiers = [NSMutableDictionary dictionary];
    _subtitleIdentifiers = [NSMutableDictionary dictionary];
    _videoView = (NSOpenGLView *)videoView;
    _handle = mpv_create();
    if (_handle == NULL) {
        return self;
    }

    mpv_set_option_string(_handle, "config", "no");
    mpv_set_option_string(_handle, "terminal", "no");
    mpv_set_option_string(_handle, "hwdec", "videotoolbox");
    mpv_set_option_string(_handle, "hwdec-software-fallback", "no");
    mpv_set_option_string(_handle, "keep-open", "yes");
    mpv_set_option_string(_handle, "vo", "libmpv");
    mpv_set_option_string(_handle, "audio-display", "embedded-first");

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

    mpv_observe_property(_handle, 1, "pause", MPV_FORMAT_FLAG);
    mpv_observe_property(_handle, 2, "time-pos", MPV_FORMAT_DOUBLE);
    mpv_observe_property(_handle, 3, "duration", MPV_FORMAT_DOUBLE);
    mpv_observe_property(_handle, 4, "speed", MPV_FORMAT_DOUBLE);
    mpv_observe_property(_handle, 5, "volume", MPV_FORMAT_DOUBLE);
    mpv_observe_property(_handle, 6, "mute", MPV_FORMAT_FLAG);
    _playbackRate = 1;
    _playerVolume = 1;
    _muted = NO;
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

- (void)loadURL:(NSURL *)url loadID:(uint64_t)loadID {
    [self performLoadURL:url loadID:loadID hardwareDecoding:YES];
}

- (void)loadURLUsingSoftwareDecoding:(NSURL *)url loadID:(uint64_t)loadID {
    [self performLoadURL:url loadID:loadID hardwareDecoding:NO];
}

- (void)play {
    [self performCommand:@[ @"set", @"pause", @"no" ]];
}

- (void)pause {
    [self performCommand:@[ @"set", @"pause", @"yes" ]];
}

- (void)stop {
    [self performCommand:@[ @"stop" ]];
}

- (void)seekTo:(double)position {
    NSString *value = [NSString stringWithFormat:@"%.6f", MAX(0, position)];
    dispatch_async(_queue, ^{
        if (self->_handle == NULL) {
            [self reportFailure:MPVClientFailureEngineUnavailable loadID:self->_requestedLoadID];
            return;
        }
        self->_forceNextPositionReport = YES;
        int result = [self executeCommand:@[ @"seek", value, @"absolute+exact" ]];
        if (result < 0) {
            self->_forceNextPositionReport = NO;
            [self reportFailure:[self failureForError:result] loadID:self->_requestedLoadID];
        }
    });
}

- (void)setPlaybackRate:(double)rate {
    NSString *value = [NSString stringWithFormat:@"%.6f", MIN(MAX(rate, 0.25), 4.0)];
    [self performCommand:@[ @"set", @"speed", value ]];
}

- (void)setPlayerVolume:(double)volume {
    NSString *value = [NSString stringWithFormat:@"%.3f", MIN(MAX(volume, 0), 1) * 100];
    [self performCommand:@[ @"set", @"volume", value ]];
}

- (void)setMuted:(BOOL)muted {
    [self performCommand:@[ @"set", @"mute", muted ? @"yes" : @"no" ]];
}

- (void)selectAudioTrack:(NSUUID *)identifier completion:(void (^)(BOOL))completion {
    dispatch_async(_queue, ^{
        NSNumber *rawID = self->_audioTrackIDs[identifier];
        BOOL success = rawID != nil && [self setTrackProperty:@"aid" rawID:rawID];
        completion(success);
    });
}

- (void)selectSubtitleTrack:(NSUUID *)identifier completion:(void (^)(BOOL))completion {
    dispatch_async(_queue, ^{
        if (identifier == nil) {
            completion(mpv_set_property_string(self->_handle, "sid", "no") >= 0);
            return;
        }
        NSNumber *rawID = self->_subtitleTrackIDs[identifier];
        BOOL success = rawID != nil && [self setTrackProperty:@"sid" rawID:rawID];
        completion(success);
    });
}

- (void)loadExternalSubtitleURL:(NSURL *)url completion:(void (^)(MPVClientExternalSubtitleResult, NSUUID *))completion {
    dispatch_async(_queue, ^{
        if (![[NSFileManager defaultManager] isReadableFileAtPath:url.path]) {
            completion(MPVClientExternalSubtitleResultMissing, nil);
            return;
        }
        int result = [self executeCommand:@[ @"sub-add", url.path, @"select" ]];
        if (result < 0) {
            completion(MPVClientExternalSubtitleResultDamaged, nil);
            return;
        }
        int64_t selectedID = 0;
        if (mpv_get_property(self->_handle, "sid", MPV_FORMAT_INT64, &selectedID) < 0) {
            completion(MPVClientExternalSubtitleResultDamaged, nil);
            return;
        }
        NSNumber *rawKey = @(selectedID);
        NSUUID *identifier = self->_subtitleIdentifiers[rawKey] ?: [NSUUID UUID];
        self->_subtitleIdentifiers[rawKey] = identifier;
        self->_subtitleTrackIDs[identifier] = rawKey;
        completion(MPVClientExternalSubtitleResultLoaded, identifier);
    });
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

- (void)performLoadURL:(NSURL *)url
                loadID:(uint64_t)loadID
      hardwareDecoding:(BOOL)hardwareDecoding {
    dispatch_async(_queue, ^{
        self->_requestedLoadID = loadID;
        if (self->_handle == NULL) {
            [self reportFailure:MPVClientFailureEngineUnavailable loadID:loadID];
            return;
        }

        int result = mpv_set_property_string(
            self->_handle,
            "hwdec",
            hardwareDecoding ? "videotoolbox" : "no"
        );
        if (result < 0) {
            [self reportFailure:MPVClientFailureDecoderInitialization loadID:loadID];
            return;
        }
        result = [self executeCommand:@[ @"loadfile", url.path, @"replace" ]];
        if (result < 0) {
            [self reportFailure:[self failureForError:result] loadID:loadID];
            return;
        }
        [self->_pendingLoadIDs addObject:@(loadID)];
        self->_hasLoadedFile = NO;
        [self reportState:MPVClientPlaybackStateLoading loadID:loadID];
        result = [self executeCommand:@[ @"set", @"pause", @"no" ]];
        if (result < 0) {
            [self reportFailure:[self failureForError:result] loadID:loadID];
        }
    });
}

- (void)performCommand:(NSArray<NSString *> *)arguments {
    dispatch_async(_queue, ^{
        if (self->_handle == NULL) {
            [self reportFailure:MPVClientFailureEngineUnavailable loadID:self->_requestedLoadID];
            return;
        }

        int result = [self executeCommand:arguments];
        if (result < 0) {
            [self reportFailure:[self failureForError:result] loadID:self->_requestedLoadID];
        }
    });
}

- (int)executeCommand:(NSArray<NSString *> *)arguments {
    const char *command[arguments.count + 1];
    for (NSUInteger index = 0; index < arguments.count; index++) {
        command[index] = arguments[index].UTF8String;
    }
    command[arguments.count] = NULL;

    return mpv_command(_handle, command);
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
            case MPV_EVENT_START_FILE:
                [self handleStartFile:event];
                break;
            case MPV_EVENT_FILE_LOADED:
                _hasLoadedFile = YES;
                [self reportCurrentPauseState];
                [self reportTrackCatalog];
                [self reportMediaPresentation];
                break;
            case MPV_EVENT_PROPERTY_CHANGE:
                [self handlePropertyChange:event];
                break;
            case MPV_EVENT_END_FILE:
                [self handleEndFile:event];
                break;
            case MPV_EVENT_SHUTDOWN:
                [self reportState:MPVClientPlaybackStateStopped loadID:_requestedLoadID];
                break;
            default:
                break;
        }
    }
}

- (void)handleStartFile:(mpv_event *)event {
    mpv_event_start_file *startFile = event->data;
    if (startFile == NULL || _pendingLoadIDs.count == 0) {
        return;
    }
    NSNumber *loadID = _pendingLoadIDs.firstObject;
    [_pendingLoadIDs removeObjectAtIndex:0];
    _loadIDsByPlaylistEntryID[@(startFile->playlist_entry_id)] = loadID;
    _eventLoadID = loadID.unsignedLongLongValue;
    _hasLoadedFile = NO;
    _position = 0;
    _duration = 0;
    _lastTimelineReportTime = 0;
    [_audioTrackIDs removeAllObjects];
    [_subtitleTrackIDs removeAllObjects];
    [_audioIdentifiers removeAllObjects];
    [_subtitleIdentifiers removeAllObjects];
}

- (BOOL)setTrackProperty:(NSString *)property rawID:(NSNumber *)rawID {
    if (_handle == NULL) {
        return NO;
    }
    return mpv_set_property_string(_handle, property.UTF8String, rawID.stringValue.UTF8String) >= 0;
}

- (void)reportTrackCatalog {
    if (_handle == NULL) {
        return;
    }
    int64_t count = 0;
    if (mpv_get_property(_handle, "track-list/count", MPV_FORMAT_INT64, &count) < 0) {
        return;
    }
    NSMutableArray<MPVClientTrack *> *audioTracks = [NSMutableArray array];
    NSMutableArray<MPVClientTrack *> *subtitleTracks = [NSMutableArray array];
    NSInteger audioOrdinal = 0;
    NSInteger subtitleOrdinal = 0;
    for (int64_t index = 0; index < count; index++) {
        NSString *prefix = [NSString stringWithFormat:@"track-list/%lld", index];
        NSString *type = [self stringProperty:[prefix stringByAppendingString:@"/type"]];
        int64_t rawID = [self integerProperty:[prefix stringByAppendingString:@"/id"] fallback:-1];
        if (rawID < 0 || (! [type isEqualToString:@"audio"] && ! [type isEqualToString:@"sub"])) {
            continue;
        }
        NSNumber *rawKey = @(rawID);
        BOOL isAudio = [type isEqualToString:@"audio"];
        if (!isAudio && [self flagProperty:[prefix stringByAppendingString:@"/external"]]) {
            continue;
        }
        NSMutableDictionary<NSNumber *, NSUUID *> *identifiers = isAudio ? _audioIdentifiers : _subtitleIdentifiers;
        NSMutableDictionary<NSUUID *, NSNumber *> *rawIDs = isAudio ? _audioTrackIDs : _subtitleTrackIDs;
        NSUUID *identifier = identifiers[rawKey] ?: [NSUUID UUID];
        identifiers[rawKey] = identifier;
        rawIDs[identifier] = rawKey;
        NSInteger ordinal = isAudio ? ++audioOrdinal : ++subtitleOrdinal;
        MPVClientTrack *track = [[MPVClientTrack alloc]
            initWithIdentifier:identifier
            languageCode:[self stringProperty:[prefix stringByAppendingString:@"/lang"]]
            title:[self stringProperty:[prefix stringByAppendingString:@"/title"]]
            ordinal:ordinal
            isDefault:[self flagProperty:[prefix stringByAppendingString:@"/default"]]
            isForced:[self flagProperty:[prefix stringByAppendingString:@"/forced"]]];
        [isAudio ? audioTracks : subtitleTracks addObject:track];
    }
    if (self.trackCatalogHandler != nil) {
        self.trackCatalogHandler(audioTracks, subtitleTracks, _eventLoadID);
    }
}

- (void)reportMediaPresentation {
    if (_handle == NULL || self.mediaPresentationHandler == nil) {
        return;
    }
    int64_t trackCount = 0;
    mpv_get_property(_handle, "track-list/count", MPV_FORMAT_INT64, &trackCount);
    BOOL hasAudio = NO;
    BOOL hasPlayableVideo = NO;
    BOOL hasArtwork = NO;
    for (int64_t index = 0; index < trackCount; index++) {
        NSString *prefix = [NSString stringWithFormat:@"track-list/%lld", index];
        NSString *type = [self stringProperty:[prefix stringByAppendingString:@"/type"]];
        if ([type isEqualToString:@"audio"]) {
            hasAudio = YES;
        } else if ([type isEqualToString:@"video"]) {
            BOOL isArtwork = [self flagProperty:[prefix stringByAppendingString:@"/albumart"]];
            hasArtwork = hasArtwork || isArtwork;
            hasPlayableVideo = hasPlayableVideo || !isArtwork;
        }
    }

    NSMutableDictionary<NSString *, NSString *> *metadata = [NSMutableDictionary dictionary];
    int64_t metadataCount = 0;
    if (mpv_get_property(_handle, "metadata/list/count", MPV_FORMAT_INT64, &metadataCount) >= 0) {
        for (int64_t index = 0; index < metadataCount; index++) {
            NSString *prefix = [NSString stringWithFormat:@"metadata/list/%lld", index];
            NSString *key = [self stringProperty:[prefix stringByAppendingString:@"/key"]];
            NSString *value = [self stringProperty:[prefix stringByAppendingString:@"/value"]];
            if (key.length > 0 && value.length > 0) {
                metadata[key.lowercaseString] = value;
            }
        }
    }

    NSString *title = metadata[@"title"] ?: [self stringProperty:@"media-title"] ?: @"未知标题";
    MPVClientMediaKind kind = hasAudio && !hasPlayableVideo
        ? MPVClientMediaKindAudio
        : MPVClientMediaKindVideo;
    self.mediaPresentationHandler(
        kind,
        title,
        metadata[@"artist"],
        metadata[@"album"],
        hasArtwork,
        _eventLoadID
    );
}

- (nullable NSString *)stringProperty:(NSString *)name {
    char *value = mpv_get_property_string(_handle, name.UTF8String);
    if (value == NULL) {
        return nil;
    }
    NSString *result = [NSString stringWithUTF8String:value];
    mpv_free(value);
    return result;
}

- (int64_t)integerProperty:(NSString *)name fallback:(int64_t)fallback {
    int64_t value = fallback;
    return mpv_get_property(_handle, name.UTF8String, MPV_FORMAT_INT64, &value) < 0 ? fallback : value;
}

- (BOOL)flagProperty:(NSString *)name {
    int value = 0;
    return mpv_get_property(_handle, name.UTF8String, MPV_FORMAT_FLAG, &value) >= 0 && value != 0;
}

- (void)handlePropertyChange:(mpv_event *)event {
    if (!_hasLoadedFile) {
        return;
    }
    mpv_event_property *property = event->data;
    if (property == NULL || property->data == NULL) {
        return;
    }
    if (strcmp(property->name, "pause") == 0 && property->format == MPV_FORMAT_FLAG) {
        int paused = *(int *)property->data;
        [self reportState:paused ? MPVClientPlaybackStatePaused : MPVClientPlaybackStatePlaying
                  loadID:_eventLoadID];
    } else if (strcmp(property->name, "time-pos") == 0 && property->format == MPV_FORMAT_DOUBLE) {
        _position = *(double *)property->data;
        BOOL force = _forceNextPositionReport;
        _forceNextPositionReport = NO;
        [self reportTimelineIfNeeded:force];
    } else if (strcmp(property->name, "duration") == 0 && property->format == MPV_FORMAT_DOUBLE) {
        _duration = *(double *)property->data;
        [self reportTimelineIfNeeded:YES];
    } else if (strcmp(property->name, "speed") == 0 && property->format == MPV_FORMAT_DOUBLE) {
        _playbackRate = *(double *)property->data;
        [self reportSettings];
    } else if (strcmp(property->name, "volume") == 0 && property->format == MPV_FORMAT_DOUBLE) {
        _playerVolume = *(double *)property->data / 100;
        [self reportSettings];
    } else if (strcmp(property->name, "mute") == 0 && property->format == MPV_FORMAT_FLAG) {
        _muted = *(int *)property->data != 0;
        [self reportSettings];
    }
}

- (void)reportSettings {
    if (self.settingsHandler != nil) {
        self.settingsHandler(_playbackRate, _playerVolume, _muted, _eventLoadID);
    }
}

- (void)reportTimelineIfNeeded:(BOOL)force {
    CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
    if (!force && now - _lastTimelineReportTime < 0.25) {
        return;
    }
    _lastTimelineReportTime = now;
    if (self.timelineHandler != nil) {
        self.timelineHandler(MAX(0, _position), MAX(0, _duration), _eventLoadID);
    }
}

- (void)handleEndFile:(mpv_event *)event {
    mpv_event_end_file *endFile = event->data;
    uint64_t loadID = _eventLoadID;
    NSNumber *playlistEntryID = nil;
    if (endFile != NULL) {
        playlistEntryID = @(endFile->playlist_entry_id);
        NSNumber *mappedLoadID = _loadIDsByPlaylistEntryID[playlistEntryID];
        if (mappedLoadID != nil) {
            loadID = mappedLoadID.unsignedLongLongValue;
        }
    }
    if (loadID == _eventLoadID) {
        _hasLoadedFile = NO;
    }
    if (endFile != NULL && endFile->reason == MPV_END_FILE_REASON_ERROR) {
        [self reportFailure:[self failureForError:endFile->error] loadID:loadID];
    } else if (endFile != NULL && endFile->reason == MPV_END_FILE_REASON_EOF) {
        if (self.playbackEndedHandler != nil) {
            self.playbackEndedHandler(loadID);
        }
    } else if (loadID == _requestedLoadID) {
        [self reportState:MPVClientPlaybackStateStopped loadID:loadID];
    }
    if (playlistEntryID != nil) {
        [_loadIDsByPlaylistEntryID removeObjectForKey:playlistEntryID];
    }
}

- (void)reportCurrentPauseState {
    int paused = 0;
    if (mpv_get_property(_handle, "pause", MPV_FORMAT_FLAG, &paused) < 0) {
        return;
    }
    [self reportState:paused ? MPVClientPlaybackStatePaused : MPVClientPlaybackStatePlaying
              loadID:_eventLoadID];
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

- (void)reportState:(MPVClientPlaybackState)state loadID:(uint64_t)loadID {
    if (self.stateHandler != nil) {
        self.stateHandler(state, loadID);
    }
}

- (void)reportFailure:(MPVClientFailure)failure loadID:(uint64_t)loadID {
    if (self.failureHandler != nil) {
        self.failureHandler(failure, loadID);
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
