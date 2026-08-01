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

@property (nonatomic, copy, nullable) void (^stateHandler)(MPVClientPlaybackState state);
@property (nonatomic, copy, nullable) void (^failureHandler)(MPVClientFailure failure);
@property (nonatomic, copy, nullable) void (^playbackEndedHandler)(void);

- (instancetype)initWithVideoView:(NSView *)videoView;
- (void)loadURL:(NSURL *)url;
- (void)play;
- (void)pause;
- (void)stop;
- (void)shutdown;

@end

NS_ASSUME_NONNULL_END
