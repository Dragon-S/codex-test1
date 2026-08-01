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

typedef NS_ENUM(NSInteger, MPVClientExternalSubtitleResult) {
    MPVClientExternalSubtitleResultLoaded,
    MPVClientExternalSubtitleResultMissing,
    MPVClientExternalSubtitleResultDamaged,
};

@interface MPVClientTrack : NSObject

@property (nonatomic, readonly) NSUUID *identifier;
@property (nonatomic, copy, readonly, nullable) NSString *languageCode;
@property (nonatomic, copy, readonly, nullable) NSString *title;
@property (nonatomic, readonly) NSInteger ordinal;
@property (nonatomic, readonly, getter=isDefault) BOOL defaultTrack;
@property (nonatomic, readonly, getter=isForced) BOOL forced;

- (instancetype)initWithIdentifier:(NSUUID *)identifier
                      languageCode:(nullable NSString *)languageCode
                              title:(nullable NSString *)title
                            ordinal:(NSInteger)ordinal
                          isDefault:(BOOL)isDefault
                            isForced:(BOOL)isForced;

@end

@interface MPVClient : NSObject

@property (nonatomic, copy, nullable) void (^stateHandler)(MPVClientPlaybackState state, uint64_t loadID);
@property (nonatomic, copy, nullable) void (^failureHandler)(MPVClientFailure failure, uint64_t loadID);
@property (nonatomic, copy, nullable) void (^playbackEndedHandler)(uint64_t loadID);
@property (nonatomic, copy, nullable) void (^timelineHandler)(double position, double duration, uint64_t loadID);
@property (nonatomic, copy, nullable) void (^settingsHandler)(double rate, double volume, BOOL muted, uint64_t loadID);
@property (nonatomic, copy, nullable) void (^trackCatalogHandler)(NSArray<MPVClientTrack *> *audioTracks, NSArray<MPVClientTrack *> *subtitleTracks, uint64_t loadID);

- (instancetype)initWithVideoView:(NSView *)videoView;
- (void)loadURL:(NSURL *)url loadID:(uint64_t)loadID;
- (void)play;
- (void)pause;
- (void)stop;
- (void)seekTo:(double)position;
- (void)setPlaybackRate:(double)rate;
- (void)setPlayerVolume:(double)volume;
- (void)setMuted:(BOOL)muted;
- (void)selectAudioTrack:(NSUUID *)identifier completion:(void (^)(BOOL success))completion;
- (void)selectSubtitleTrack:(nullable NSUUID *)identifier completion:(void (^)(BOOL success))completion;
- (void)loadExternalSubtitleURL:(NSURL *)url completion:(void (^)(MPVClientExternalSubtitleResult result, NSUUID * _Nullable identifier))completion;
- (void)shutdown;

@end

NS_ASSUME_NONNULL_END
