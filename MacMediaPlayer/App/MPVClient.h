#import <AppKit/AppKit.h>

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, MPVClientPlaybackState) {
    MPVClientPlaybackStateLoading,
    MPVClientPlaybackStatePlaying,
    MPVClientPlaybackStatePaused,
    MPVClientPlaybackStateStopped,
};

typedef NS_ENUM(NSInteger, MPVClientFailure) {
    MPVClientFailureUnreadable,
    MPVClientFailureUnsupported,
    MPVClientFailureCorrupted,
    MPVClientFailureDecoderInitialization,
    MPVClientFailureEngineUnavailable,
};

@interface MPVClient : NSObject

@property (nonatomic, copy, nullable) void (^stateHandler)(MPVClientPlaybackState state, uint64_t loadID);
@property (nonatomic, copy, nullable) void (^failureHandler)(MPVClientFailure failure, uint64_t loadID);
@property (nonatomic, copy, nullable) void (^playbackEndedHandler)(uint64_t loadID);
@property (nonatomic, copy, nullable) void (^timelineHandler)(double position, double duration, uint64_t loadID);
@property (nonatomic, copy, nullable) void (^settingsHandler)(double rate, double volume, BOOL muted, uint64_t loadID);

- (instancetype)initWithVideoView:(NSView *)videoView;
- (void)loadURL:(NSURL *)url loadID:(uint64_t)loadID;
- (void)play;
- (void)pause;
- (void)stop;
- (void)seekTo:(double)position;
- (void)setPlaybackRate:(double)rate;
- (void)setPlayerVolume:(double)volume;
- (void)setMuted:(BOOL)muted;
- (void)shutdown;

@end

NS_ASSUME_NONNULL_END
