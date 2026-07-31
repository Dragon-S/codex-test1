#import <Cocoa/Cocoa.h>
#import <OpenGL/gl3.h>
#import <QuartzCore/QuartzCore.h>
#import <dlfcn.h>
#import <mach/mach.h>
#import <mpv/client.h>
#import <mpv/render.h>
#import <mpv/render_gl.h>

static NSString *const PrototypeWarning =
    @"一次性验证原型，不是产品代码。每次操作都会把完整状态写入 JSONL。";

@interface MpvOpenGLView : NSOpenGLView
@property(nonatomic) mpv_render_context *renderContext;
@property(nonatomic, copy) NSString *pendingCapturePath;
- (int)configureWithMpv:(mpv_handle *)mpv;
- (BOOL)captureFrameToPath:(NSString *)path;
- (void)shutdownRenderer;
@end

static void *resolveOpenGLSymbol(void *context, const char *name) {
    (void)context;
    return dlsym(RTLD_DEFAULT, name);
}

static void requestMpvRender(void *context) {
    MpvOpenGLView *view = (__bridge MpvOpenGLView *)context;
    dispatch_async(dispatch_get_main_queue(), ^{
        [view setNeedsDisplay:YES];
    });
}

@implementation MpvOpenGLView

- (instancetype)initWithFrame:(NSRect)frameRect {
    NSOpenGLPixelFormatAttribute attributes[] = {
        NSOpenGLPFAOpenGLProfile,
        NSOpenGLProfileVersion3_2Core,
        NSOpenGLPFAAccelerated,
        NSOpenGLPFADoubleBuffer,
        NSOpenGLPFAColorSize,
        24,
        NSOpenGLPFAAlphaSize,
        8,
        0
    };
    NSOpenGLPixelFormat *format =
        [[NSOpenGLPixelFormat alloc] initWithAttributes:attributes];
    self = [super initWithFrame:frameRect pixelFormat:format];
    if (self) {
        self.wantsBestResolutionOpenGLSurface = YES;
    }
    return self;
}

- (int)configureWithMpv:(mpv_handle *)mpv {
    [self.openGLContext makeCurrentContext];
    mpv_opengl_init_params openGL = {
        .get_proc_address = resolveOpenGLSymbol,
        .get_proc_address_ctx = NULL,
    };
    const char *apiType = MPV_RENDER_API_TYPE_OPENGL;
    mpv_render_param parameters[] = {
        {MPV_RENDER_PARAM_API_TYPE, (void *)apiType},
        {MPV_RENDER_PARAM_OPENGL_INIT_PARAMS, &openGL},
        {MPV_RENDER_PARAM_INVALID, NULL},
    };
    int result =
        mpv_render_context_create(&_renderContext, mpv, parameters);
    if (result >= 0) {
        mpv_render_context_set_update_callback(
            self.renderContext, requestMpvRender, (__bridge void *)self);
    }
    return result;
}

- (void)drawRect:(NSRect)dirtyRect {
    (void)dirtyRect;
    if (self.renderContext == NULL) {
        [[NSColor blackColor] setFill];
        NSRectFill(self.bounds);
        return;
    }

    [self.openGLContext makeCurrentContext];
    NSRect backingBounds = [self convertRectToBacking:self.bounds];
    mpv_opengl_fbo framebuffer = {
        .fbo = 0,
        .w = (int)backingBounds.size.width,
        .h = (int)backingBounds.size.height,
        .internal_format = 0,
    };
    int flip = 1;
    mpv_render_param parameters[] = {
        {MPV_RENDER_PARAM_OPENGL_FBO, &framebuffer},
        {MPV_RENDER_PARAM_FLIP_Y, &flip},
        {MPV_RENDER_PARAM_INVALID, NULL},
    };
    mpv_render_context_render(self.renderContext, parameters);
    if (self.pendingCapturePath.length > 0) {
        [self writeCurrentFramebufferWithWidth:framebuffer.w
                                        height:framebuffer.h
                                          path:self.pendingCapturePath];
        self.pendingCapturePath = nil;
    }
    [self.openGLContext flushBuffer];
    mpv_render_context_report_swap(self.renderContext);
}

- (void)writeCurrentFramebufferWithWidth:(int)width
                                  height:(int)height
                                    path:(NSString *)path {
    NSBitmapImageRep *bitmap = [[NSBitmapImageRep alloc]
        initWithBitmapDataPlanes:NULL
                      pixelsWide:width
                      pixelsHigh:height
                   bitsPerSample:8
                 samplesPerPixel:4
                        hasAlpha:YES
                        isPlanar:NO
                  colorSpaceName:NSDeviceRGBColorSpace
                     bitmapFormat:NSBitmapFormatAlphaNonpremultiplied
                      bytesPerRow:0
                     bitsPerPixel:0];
    glPixelStorei(GL_PACK_ALIGNMENT, 1);
    glReadPixels(0,
                 0,
                 width,
                 height,
                 GL_RGBA,
                 GL_UNSIGNED_BYTE,
                 bitmap.bitmapData);

    NSUInteger bytesPerRow = bitmap.bytesPerRow;
    uint8_t *temporaryRow = malloc(bytesPerRow);
    for (int row = 0; row < height / 2; row++) {
        uint8_t *top = bitmap.bitmapData + row * bytesPerRow;
        uint8_t *bottom = bitmap.bitmapData + (height - row - 1) * bytesPerRow;
        memcpy(temporaryRow, top, bytesPerRow);
        memcpy(top, bottom, bytesPerRow);
        memcpy(bottom, temporaryRow, bytesPerRow);
    }
    free(temporaryRow);

    NSData *png = [bitmap representationUsingType:NSBitmapImageFileTypePNG
                                       properties:@{}];
    [png writeToFile:path atomically:YES];
}

- (BOOL)captureFrameToPath:(NSString *)path {
    self.pendingCapturePath = path;
    [self setNeedsDisplay:YES];
    [self displayIfNeeded];
    return [NSFileManager.defaultManager fileExistsAtPath:path];
}

- (void)reshape {
    [super reshape];
    [self setNeedsDisplay:YES];
}

- (void)shutdownRenderer {
    if (self.renderContext != NULL) {
        [self.openGLContext makeCurrentContext];
        mpv_render_context_set_update_callback(self.renderContext, NULL, NULL);
        mpv_render_context_free(self.renderContext);
        self.renderContext = NULL;
    }
}

- (void)dealloc {
    [self shutdownRenderer];
}

@end

@interface ProbeDelegate : NSObject <NSApplicationDelegate, NSWindowDelegate>
@property(nonatomic, strong) NSWindow *window;
@property(nonatomic, strong) MpvOpenGLView *videoView;
@property(nonatomic, strong) NSTextField *statusLabel;
@property(nonatomic, strong) NSSlider *positionSlider;
@property(nonatomic, strong) NSPopUpButton *speedPicker;
@property(nonatomic, strong) NSTimer *eventTimer;
@property(nonatomic, strong) NSTimer *autoExitTimer;
@property(nonatomic, strong) NSFileHandle *logHandle;
@property(nonatomic, copy) NSString *mediaPath;
@property(nonatomic, copy) NSString *sampleID;
@property(nonatomic, copy) NSString *mediaSHA256;
@property(nonatomic, copy) NSString *evidenceDirectory;
@property(nonatomic, copy) NSString *logPath;
@property(nonatomic, copy) NSString *pendingScreenshotPath;
@property(nonatomic) mpv_handle *mpv;
@property(nonatomic) NSTimeInterval startedAt;
@property(nonatomic) NSTimeInterval loadRequestedAt;
@property(nonatomic) NSTimeInterval restartRequestedAt;
@property(nonatomic, copy) NSString *pendingRestartAction;
@property(nonatomic) double pendingResumePosition;
@property(nonatomic) BOOL restoreResumeAfterLoad;
@property(nonatomic) BOOL sliderIsTracking;
@property(nonatomic) NSTimeInterval autoExitSeconds;
@property(nonatomic) BOOL muteAudio;
@end

@implementation ProbeDelegate

- (instancetype)initWithMediaPath:(NSString *)mediaPath
                         sampleID:(NSString *)sampleID
                      mediaSHA256:(NSString *)mediaSHA256
                 evidenceDirectory:(NSString *)evidenceDirectory
                    autoExitSeconds:(NSTimeInterval)autoExitSeconds
                           muteAudio:(BOOL)muteAudio {
    self = [super init];
    if (self) {
        _mediaPath = [mediaPath copy];
        _sampleID = [sampleID copy];
        _mediaSHA256 = [mediaSHA256 copy];
        _evidenceDirectory = [evidenceDirectory copy];
        _autoExitSeconds = autoExitSeconds;
        _muteAudio = muteAudio;
        _startedAt = NSProcessInfo.processInfo.systemUptime;
        _pendingResumePosition = -1;
    }
    return self;
}

- (void)applicationDidFinishLaunching:(NSNotification *)notification {
    (void)notification;
    [self createEvidenceLog];
    [self createWindow];
    [self initializeMpv];
    [self observeProperties];
    [self loadMedia];

    self.eventTimer = [NSTimer scheduledTimerWithTimeInterval:0.02
                                                      target:self
                                                    selector:@selector(drainEvents:)
                                                    userInfo:nil
                                                     repeats:YES];
    if (self.autoExitSeconds > 0) {
        self.autoExitTimer =
            [NSTimer scheduledTimerWithTimeInterval:self.autoExitSeconds
                                             target:self
                                           selector:@selector(autoExit:)
                                           userInfo:nil
                                            repeats:NO];
    }
    [self.window makeKeyAndOrderFront:nil];
    [NSApp activateIgnoringOtherApps:YES];
}

- (void)autoExit:(NSTimer *)timer {
    (void)timer;
    [self logKind:@"action"
            fields:@{
                @"action" : @"auto_exit",
                @"configured_seconds" : @(self.autoExitSeconds),
                @"state" : [self snapshot]
            }];
    [NSApp terminate:nil];
}

- (void)createEvidenceLog {
    NSFileManager *manager = NSFileManager.defaultManager;
    [manager createDirectoryAtPath:self.evidenceDirectory
       withIntermediateDirectories:YES
                        attributes:nil
                             error:nil];

    NSDateFormatter *formatter = [[NSDateFormatter alloc] init];
    formatter.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
    formatter.dateFormat = @"yyyyMMdd-HHmmss";
    NSString *stamp = [formatter stringFromDate:NSDate.date];
    self.logPath = [self.evidenceDirectory
        stringByAppendingPathComponent:[NSString stringWithFormat:@"probe-%@.jsonl", stamp]];
    [manager createFileAtPath:self.logPath contents:nil attributes:nil];
    self.logHandle = [NSFileHandle fileHandleForWritingAtPath:self.logPath];
}

- (NSButton *)buttonWithTitle:(NSString *)title
                       action:(SEL)action
                        frame:(NSRect)frame {
    NSButton *button = [NSButton buttonWithTitle:title target:self action:action];
    button.frame = frame;
    button.bezelStyle = NSBezelStyleRounded;
    return button;
}

- (void)createWindow {
    NSRect frame = NSMakeRect(0, 0, 1100, 760);
    self.window = [[NSWindow alloc]
        initWithContentRect:frame
                  styleMask:(NSWindowStyleMaskTitled |
                             NSWindowStyleMaskClosable |
                             NSWindowStyleMaskMiniaturizable |
                             NSWindowStyleMaskResizable)
                    backing:NSBackingStoreBuffered
                      defer:NO];
    self.window.title = @"PROTOTYPE — libmpv MVP 语料探针";
    self.window.delegate = self;
    [self.window center];

    NSView *root = [[NSView alloc] initWithFrame:frame];
    self.window.contentView = root;

    self.videoView =
        [[MpvOpenGLView alloc] initWithFrame:NSMakeRect(20, 180, 1060, 560)];
    self.videoView.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    [root addSubview:self.videoView];

    self.positionSlider = [[NSSlider alloc] initWithFrame:NSMakeRect(20, 142, 1060, 24)];
    self.positionSlider.minValue = 0;
    self.positionSlider.maxValue = 100;
    self.positionSlider.target = self;
    self.positionSlider.action = @selector(scrub:);
    self.positionSlider.continuous = NO;
    self.positionSlider.autoresizingMask = NSViewWidthSizable | NSViewMinYMargin;
    [root addSubview:self.positionSlider];

    NSArray<NSButton *> *buttons = @[
        [self buttonWithTitle:@"播放/暂停" action:@selector(togglePause:) frame:NSMakeRect(20, 102, 105, 30)],
        [self buttonWithTitle:@"后退 10 秒" action:@selector(seekBackward:) frame:NSMakeRect(135, 102, 105, 30)],
        [self buttonWithTitle:@"前进 10 秒" action:@selector(seekForward:) frame:NSMakeRect(250, 102, 105, 30)],
        [self buttonWithTitle:@"切换音轨" action:@selector(cycleAudio:) frame:NSMakeRect(365, 102, 105, 30)],
        [self buttonWithTitle:@"切换字幕" action:@selector(cycleSubtitle:) frame:NSMakeRect(480, 102, 105, 30)],
        [self buttonWithTitle:@"硬解/软解" action:@selector(toggleHardwareDecode:) frame:NSMakeRect(595, 102, 105, 30)],
        [self buttonWithTitle:@"续播往返" action:@selector(resumeRoundTrip:) frame:NSMakeRect(710, 102, 105, 30)],
        [self buttonWithTitle:@"截图证据" action:@selector(captureScreenshot:) frame:NSMakeRect(825, 102, 105, 30)]
    ];
    for (NSButton *button in buttons) {
        button.autoresizingMask = NSViewMaxYMargin;
        [root addSubview:button];
    }

    self.speedPicker = [[NSPopUpButton alloc] initWithFrame:NSMakeRect(940, 102, 140, 30)];
    [self.speedPicker addItemsWithTitles:@[@"0.5×", @"1.0×", @"1.25×", @"1.5×", @"2.0×"]];
    [self.speedPicker selectItemWithTitle:@"1.0×"];
    self.speedPicker.target = self;
    self.speedPicker.action = @selector(changeSpeed:);
    [root addSubview:self.speedPicker];

    self.statusLabel = [NSTextField wrappingLabelWithString:PrototypeWarning];
    self.statusLabel.frame = NSMakeRect(20, 16, 1060, 76);
    self.statusLabel.font = [NSFont monospacedSystemFontOfSize:12
                                                       weight:NSFontWeightRegular];
    self.statusLabel.autoresizingMask = NSViewWidthSizable | NSViewMaxYMargin;
    [root addSubview:self.statusLabel];
}

- (void)initializeMpv {
    self.mpv = mpv_create();
    if (self.mpv == NULL) {
        [self fatal:@"mpv_create 返回空指针"];
        return;
    }

    mpv_set_option_string(self.mpv, "config", "no");
    mpv_set_option_string(self.mpv, "terminal", "no");
    mpv_set_option_string(self.mpv, "input-default-bindings", "no");
    mpv_set_option_string(self.mpv, "input-vo-keyboard", "no");
    mpv_set_option_string(self.mpv, "hwdec", "videotoolbox,auto-safe");
    mpv_set_option_string(self.mpv, "keep-open", "yes");
    mpv_set_option_string(self.mpv, "vo", "libmpv");
    if (self.muteAudio) {
        mpv_set_option_string(self.mpv, "mute", "yes");
    }

    int result = mpv_initialize(self.mpv);
    if (result < 0) {
        [self fatal:[NSString stringWithFormat:@"mpv_initialize: %s",
                                               mpv_error_string(result)]];
        return;
    }
    result = [self.videoView configureWithMpv:self.mpv];
    if (result < 0) {
        [self fatal:[NSString stringWithFormat:@"mpv_render_context_create: %s",
                                               mpv_error_string(result)]];
        return;
    }
    mpv_request_log_messages(self.mpv, "info");
    [self logKind:@"session_started"
           fields:@{
               @"sample_id" : self.sampleID,
               @"media_sha256" : self.mediaSHA256,
               @"mpv_client_api" : [NSString
                   stringWithFormat:@"%lu.%lu",
                                    (unsigned long)(mpv_client_api_version() >> 16),
                                    (unsigned long)(mpv_client_api_version() & 0xffff)],
               @"mute_audio" : @(self.muteAudio),
               @"warning" : PrototypeWarning
           }];
}

- (void)observeProperties {
    NSArray<NSString *> *properties = @[
        @"time-pos", @"duration", @"pause", @"speed", @"seeking",
        @"playback-time", @"hwdec-current", @"video-codec", @"video-format",
        @"audio-codec-name", @"aid", @"sid", @"track-list/count",
        @"decoder-frame-drop-count", @"frame-drop-count", @"mistimed-frame-count",
        @"estimated-vf-fps", @"container-fps", @"avsync", @"idle-active"
    ];
    uint64_t identifier = 1;
    for (NSString *property in properties) {
        mpv_observe_property(self.mpv,
                             identifier++,
                             property.UTF8String,
                             MPV_FORMAT_NODE);
    }
}

- (void)loadMedia {
    self.loadRequestedAt = NSProcessInfo.processInfo.systemUptime;
    [self expectPlaybackRestartForAction:@"loadfile"];
    const char *command[] = {"loadfile", self.mediaPath.fileSystemRepresentation,
                             "replace", NULL};
    int result = mpv_command(self.mpv, command);
    [self logAction:@"loadfile"
             extra:@{@"result" : @(result), @"error" : @(mpv_error_string(result))}];
}

- (void)command:(NSArray<NSString *> *)arguments action:(NSString *)action {
    NSUInteger count = arguments.count;
    const char **values = calloc(count + 1, sizeof(char *));
    for (NSUInteger index = 0; index < count; index++) {
        values[index] = arguments[index].UTF8String;
    }
    int result = mpv_command(self.mpv, values);
    free(values);
    [self logAction:action
             extra:@{@"result" : @(result), @"error" : @(mpv_error_string(result))}];
}

- (void)togglePause:(id)sender {
    (void)sender;
    [self command:@[@"cycle", @"pause"] action:@"toggle_pause"];
}

- (void)seekBackward:(id)sender {
    (void)sender;
    [self expectPlaybackRestartForAction:@"seek_minus_10"];
    [self command:@[@"seek", @"-10", @"relative+exact"] action:@"seek_minus_10"];
}

- (void)seekForward:(id)sender {
    (void)sender;
    [self expectPlaybackRestartForAction:@"seek_plus_10"];
    [self command:@[@"seek", @"+10", @"relative+exact"] action:@"seek_plus_10"];
}

- (void)cycleAudio:(id)sender {
    (void)sender;
    [self command:@[@"cycle", @"audio"] action:@"cycle_audio_track"];
}

- (void)cycleSubtitle:(id)sender {
    (void)sender;
    [self command:@[@"cycle", @"sub"] action:@"cycle_subtitle_track"];
}

- (void)scrub:(NSSlider *)sender {
    NSString *percent = [NSString stringWithFormat:@"%.6f", sender.doubleValue];
    [self expectPlaybackRestartForAction:@"scrub"];
    [self command:@[@"seek", percent, @"absolute-percent+exact"] action:@"scrub"];
}

- (void)changeSpeed:(NSPopUpButton *)sender {
    NSString *value = [sender.titleOfSelectedItem
        stringByReplacingOccurrencesOfString:@"×" withString:@""];
    [self command:@[@"set", @"speed", value] action:@"change_speed"];
}

- (void)toggleHardwareDecode:(id)sender {
    (void)sender;
    NSString *current = [self stringProperty:@"hwdec"];
    NSString *next = [current isEqualToString:@"no"] ? @"videotoolbox,auto-safe" : @"no";
    self.pendingResumePosition = [self doubleProperty:@"time-pos" fallback:0];
    self.restoreResumeAfterLoad = YES;
    [self command:@[@"set", @"hwdec", next] action:@"toggle_hwdec"];
    [self loadMedia];
}

- (void)resumeRoundTrip:(id)sender {
    (void)sender;
    self.pendingResumePosition = [self doubleProperty:@"time-pos" fallback:0];
    self.restoreResumeAfterLoad = YES;
    [self logAction:@"resume_round_trip_start"
             extra:@{@"expected_position" : @(self.pendingResumePosition)}];
    [self loadMedia];
}

- (void)captureScreenshot:(id)sender {
    (void)sender;
    NSDateFormatter *formatter = [[NSDateFormatter alloc] init];
    formatter.dateFormat = @"yyyyMMdd-HHmmss-SSS";
    NSString *name = [NSString stringWithFormat:@"frame-%@.png",
                                                [formatter stringFromDate:NSDate.date]];
    self.pendingScreenshotPath =
        [self.evidenceDirectory stringByAppendingPathComponent:name];
    BOOL wroteScreenshot =
        [self.videoView captureFrameToPath:self.pendingScreenshotPath];
    [self logAction:@"capture_screenshot"
              extra:@{
                  @"result" : @(wroteScreenshot ? 0 : -1),
                  @"output" : self.pendingScreenshotPath,
                  @"capture_boundary" : @"AppKit OpenGL framebuffer"
              }];
}

- (void)drainEvents:(NSTimer *)timer {
    (void)timer;
    if (self.mpv == NULL) {
        return;
    }
    while (true) {
        mpv_event *event = mpv_wait_event(self.mpv, 0);
        if (event->event_id == MPV_EVENT_NONE) {
            break;
        }
        [self handleEvent:event];
    }
    [self refreshStatus];
}

- (void)handleEvent:(mpv_event *)event {
    NSString *name = @(mpv_event_name(event->event_id));
    NSMutableDictionary *fields = [@{@"event" : name} mutableCopy];
    if (event->error < 0) {
        fields[@"mpv_error"] = @(mpv_error_string(event->error));
    }

    if (event->event_id == MPV_EVENT_LOG_MESSAGE && event->data != NULL) {
        mpv_event_log_message *message = event->data;
        fields[@"prefix"] = @(message->prefix ?: "");
        fields[@"level"] = @(message->level ?: "");
        fields[@"text"] =
            [@(message->text ?: "") stringByTrimmingCharactersInSet:
                                      NSCharacterSet.newlineCharacterSet];
    } else if (event->event_id == MPV_EVENT_FILE_LOADED) {
        fields[@"load_to_file_loaded_ms"] =
            @((NSProcessInfo.processInfo.systemUptime - self.loadRequestedAt) * 1000);
        if (self.restoreResumeAfterLoad && self.pendingResumePosition >= 0) {
            NSString *position =
                [NSString stringWithFormat:@"%.6f", self.pendingResumePosition];
            self.restoreResumeAfterLoad = NO;
            [self expectPlaybackRestartForAction:@"resume_restore_seek"];
            [self command:@[@"seek", position, @"absolute+exact"]
                   action:@"resume_restore_seek"];
        }
    } else if (event->event_id == MPV_EVENT_PLAYBACK_RESTART) {
        if (self.pendingRestartAction.length > 0) {
            fields[@"trigger_action"] = self.pendingRestartAction;
            fields[@"action_to_restart_ms"] =
                @((NSProcessInfo.processInfo.systemUptime - self.restartRequestedAt) *
                  1000);
            self.pendingRestartAction = nil;
        }
        if (self.pendingResumePosition >= 0) {
            double actual = [self doubleProperty:@"time-pos" fallback:-1];
            fields[@"resume_expected"] = @(self.pendingResumePosition);
            fields[@"resume_actual"] = @(actual);
            fields[@"resume_error_seconds"] = @(fabs(actual - self.pendingResumePosition));
            self.pendingResumePosition = -1;
        }
    } else if (event->event_id == MPV_EVENT_END_FILE && event->data != NULL) {
        mpv_event_end_file *end = event->data;
        fields[@"reason"] = @(end->reason);
        NSString *rawError = @(mpv_error_string(end->error));
        fields[@"raw_error"] = rawError;
        fields[@"suggested_domain_error"] =
            [self suggestedDomainErrorForCode:end->error rawError:rawError];
    }
    [self logKind:@"mpv_event" fields:fields];
}

- (void)expectPlaybackRestartForAction:(NSString *)action {
    self.pendingRestartAction = action;
    self.restartRequestedAt = NSProcessInfo.processInfo.systemUptime;
}

- (NSString *)suggestedDomainErrorForCode:(int)code rawError:(NSString *)rawError {
    if ([rawError localizedCaseInsensitiveContainsString:@"unrecognized file format"]) {
        return @"格式或编码不受支持";
    }
    switch (code) {
        case MPV_ERROR_LOADING_FAILED:
            if ([self.mediaSHA256 isEqualToString:@"unavailable"]) {
                return @"无法读取文件；请检查访问权限或文件是否仍存在";
            }
            return @"无法读取或文件内容损坏（生产探测层必须进一步区分）";
        case MPV_ERROR_UNSUPPORTED:
            return @"格式或编码不受支持";
        case MPV_ERROR_PROPERTY_FORMAT:
            return @"解码器或媒体属性格式异常";
        case MPV_ERROR_NOTHING_TO_PLAY:
            return @"文件内容损坏、无可播放轨道或解码器初始化失败（需结合日志细分）";
        default:
            return code < 0 ? @"播放失败（保留原始错误供诊断）" : @"无";
    }
}

- (NSDictionary *)snapshot {
    double residentMiB = 0;
    mach_task_basic_info_data_t info;
    mach_msg_type_number_t count = MACH_TASK_BASIC_INFO_COUNT;
    if (task_info(mach_task_self(),
                  MACH_TASK_BASIC_INFO,
                  (task_info_t)&info,
                  &count) == KERN_SUCCESS) {
        residentMiB = (double)info.resident_size / 1024.0 / 1024.0;
    }
    return @{
        @"time_pos" : @([self doubleProperty:@"time-pos" fallback:-1]),
        @"duration" : @([self doubleProperty:@"duration" fallback:-1]),
        @"pause" : @([self flagProperty:@"pause"]),
        @"speed" : @([self doubleProperty:@"speed" fallback:-1]),
        @"seeking" : @([self flagProperty:@"seeking"]),
        @"hwdec_current" : [self stringProperty:@"hwdec-current"],
        @"video_codec" : [self stringProperty:@"video-codec"],
        @"video_format" : [self stringProperty:@"video-format"],
        @"audio_codec" : [self stringProperty:@"audio-codec-name"],
        @"audio_track" : [self stringProperty:@"aid"],
        @"subtitle_track" : [self stringProperty:@"sid"],
        @"track_count" : @([self intProperty:@"track-list/count" fallback:-1]),
        @"decoder_dropped_frames" :
            @([self intProperty:@"decoder-frame-drop-count" fallback:-1]),
        @"output_dropped_frames" :
            @([self intProperty:@"frame-drop-count" fallback:-1]),
        @"mistimed_frames" :
            @([self intProperty:@"mistimed-frame-count" fallback:-1]),
        @"estimated_fps" :
            @([self doubleProperty:@"estimated-vf-fps" fallback:-1]),
        @"container_fps" : @([self doubleProperty:@"container-fps" fallback:-1]),
        @"avsync_seconds" : @([self doubleProperty:@"avsync" fallback:-1]),
        @"resident_mib" : @(residentMiB)
    };
}

- (void)refreshStatus {
    NSDictionary *state = [self snapshot];
    double duration = [state[@"duration"] doubleValue];
    double position = [state[@"time_pos"] doubleValue];
    if (duration > 0 && !self.positionSlider.highlighted) {
        self.positionSlider.doubleValue = MAX(0, MIN(100, position / duration * 100));
    }
    self.statusLabel.stringValue = [NSString
        stringWithFormat:@"%@\n%.3fs / %.3fs | %@ | %@ | hwdec=%@ | "
                         "drop=%@/%@ | avsync=%@ | RSS=%@ MiB\n证据：%@",
                         PrototypeWarning,
                         position,
                         duration,
                         state[@"video_codec"],
                         state[@"audio_codec"],
                         state[@"hwdec_current"],
                         state[@"decoder_dropped_frames"],
                         state[@"output_dropped_frames"],
                         state[@"avsync_seconds"],
                         state[@"resident_mib"],
                         self.logPath];
}

- (double)doubleProperty:(NSString *)name fallback:(double)fallback {
    double value = fallback;
    if (mpv_get_property(self.mpv, name.UTF8String, MPV_FORMAT_DOUBLE, &value) < 0) {
        return fallback;
    }
    return value;
}

- (int64_t)intProperty:(NSString *)name fallback:(int64_t)fallback {
    int64_t value = fallback;
    if (mpv_get_property(self.mpv, name.UTF8String, MPV_FORMAT_INT64, &value) < 0) {
        return fallback;
    }
    return value;
}

- (BOOL)flagProperty:(NSString *)name {
    int value = 0;
    mpv_get_property(self.mpv, name.UTF8String, MPV_FORMAT_FLAG, &value);
    return value != 0;
}

- (NSString *)stringProperty:(NSString *)name {
    char *value = mpv_get_property_string(self.mpv, name.UTF8String);
    if (value == NULL) {
        return @"—";
    }
    NSString *result = @(value);
    mpv_free(value);
    return result;
}

- (void)logAction:(NSString *)action extra:(NSDictionary *)extra {
    NSMutableDictionary *fields = [@{
        @"action" : action,
        @"state" : [self snapshot]
    } mutableCopy];
    [fields addEntriesFromDictionary:extra];
    [self logKind:@"action" fields:fields];
}

- (void)logKind:(NSString *)kind fields:(NSDictionary *)fields {
    NSMutableDictionary *record = [@{
        @"kind" : kind,
        @"elapsed_ms" :
            @((NSProcessInfo.processInfo.systemUptime - self.startedAt) * 1000),
        @"recorded_at" :
            [NSISO8601DateFormatter.new stringFromDate:NSDate.date]
    } mutableCopy];
    [record addEntriesFromDictionary:fields];
    NSError *error = nil;
    NSData *json =
        [NSJSONSerialization dataWithJSONObject:record options:0 error:&error];
    if (json == nil) {
        fprintf(stderr, "JSONL 序列化失败：%s\n", error.localizedDescription.UTF8String);
        return;
    }
    [self.logHandle writeData:json];
    [self.logHandle writeData:[@"\n" dataUsingEncoding:NSUTF8StringEncoding]];
    [self.logHandle synchronizeFile];
}

- (void)fatal:(NSString *)message {
    [self logKind:@"fatal" fields:@{@"message" : message}];
    NSAlert *alert = [[NSAlert alloc] init];
    alert.messageText = @"libmpv 原型无法启动";
    alert.informativeText = message;
    [alert runModal];
    [NSApp terminate:nil];
}

- (void)windowWillClose:(NSNotification *)notification {
    (void)notification;
    [NSApp terminate:nil];
}

- (void)applicationWillTerminate:(NSNotification *)notification {
    (void)notification;
    [self.eventTimer invalidate];
    [self.autoExitTimer invalidate];
    if (self.mpv != NULL) {
        [self logKind:@"session_ended" fields:@{@"state" : [self snapshot]}];
        [self.videoView shutdownRenderer];
        mpv_terminate_destroy(self.mpv);
        self.mpv = NULL;
    }
    [self.logHandle closeFile];
}

@end

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        NSString *mediaPath = nil;
        NSString *sampleID = nil;
        NSString *mediaSHA256 = nil;
        NSString *evidenceDirectory = nil;
        NSTimeInterval autoExitSeconds = 0;
        BOOL muteAudio = NO;
        for (int index = 1; index < argc; index++) {
            NSString *argument = @(argv[index]);
            if ([argument isEqualToString:@"--media"] && index + 1 < argc) {
                mediaPath = @(argv[++index]);
            } else if ([argument isEqualToString:@"--sample-id"] &&
                       index + 1 < argc) {
                sampleID = @(argv[++index]);
            } else if ([argument isEqualToString:@"--media-sha256"] &&
                       index + 1 < argc) {
                mediaSHA256 = @(argv[++index]);
            } else if ([argument isEqualToString:@"--evidence-dir"] &&
                       index + 1 < argc) {
                evidenceDirectory = @(argv[++index]);
            } else if ([argument isEqualToString:@"--auto-exit-seconds"] &&
                       index + 1 < argc) {
                autoExitSeconds = [@(argv[++index]) doubleValue];
            } else if ([argument isEqualToString:@"--mute-audio"] &&
                       index + 1 < argc) {
                muteAudio = [@(argv[++index]) isEqualToString:@"yes"];
            }
        }
        if (mediaPath.length == 0 || sampleID.length == 0 ||
            mediaSHA256.length == 0 || evidenceDirectory.length == 0) {
            fprintf(stderr,
                    "缺少 --media、--sample-id、--media-sha256 或 "
                    "--evidence-dir\n");
            return 64;
        }

        NSApplication *application = NSApplication.sharedApplication;
        application.activationPolicy = NSApplicationActivationPolicyRegular;
        ProbeDelegate *delegate =
            [[ProbeDelegate alloc] initWithMediaPath:mediaPath
                                            sampleID:sampleID
                                         mediaSHA256:mediaSHA256
                                  evidenceDirectory:evidenceDirectory
                                     autoExitSeconds:autoExitSeconds
                                            muteAudio:muteAudio];
        application.delegate = delegate;
        [application run];
    }
    return 0;
}
