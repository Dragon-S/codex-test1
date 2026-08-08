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

typedef NS_ENUM(NSInteger, MPVClientMediaKind) {
    MPVClientMediaKindAudio,
    MPVClientMediaKindVideo,
};

typedef NSString * _Nullable (^MPVClientHardwareDecoderReader)(void);

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

@interface MPVClientMediaPresentation : NSObject

@property (nonatomic, readonly) MPVClientMediaKind kind;
@property (nonatomic, copy, readonly) NSString *title;
@property (nonatomic, copy, readonly, nullable) NSString *artist;
@property (nonatomic, copy, readonly, nullable) NSString *album;
@property (nonatomic, readonly) BOOL hasArtwork;
@property (nonatomic, readonly) NSInteger pixelWidth;
@property (nonatomic, readonly) NSInteger pixelHeight;

- (instancetype)initWithKind:(MPVClientMediaKind)kind
                        title:(NSString *)title
                       artist:(nullable NSString *)artist
                        album:(nullable NSString *)album
                   hasArtwork:(BOOL)hasArtwork
                   pixelWidth:(NSInteger)pixelWidth
                  pixelHeight:(NSInteger)pixelHeight;

@end

@interface MPVClient : NSObject

@property (nonatomic, copy, nullable) void (^stateHandler)(MPVClientPlaybackState state, uint64_t loadID);
@property (nonatomic, copy, nullable) void (^failureHandler)(MPVClientFailure failure, uint64_t loadID);
@property (nonatomic, copy, nullable) void (^playbackEndedHandler)(uint64_t loadID);
@property (nonatomic, copy, nullable) void (^timelineHandler)(double position, double duration, uint64_t loadID);
@property (nonatomic, copy, nullable) void (^settingsHandler)(double rate, double volume, BOOL muted, uint64_t loadID);
@property (nonatomic, copy, nullable) void (^trackCatalogHandler)(NSArray<MPVClientTrack *> *audioTracks, NSArray<MPVClientTrack *> *subtitleTracks, uint64_t loadID);
@property (nonatomic, copy, nullable) void (^mediaPresentationHandler)(MPVClientMediaPresentation *presentation, uint64_t loadID);

- (instancetype)initWithVideoView:(NSView *)videoView;
- (instancetype)initWithVideoView:(NSView *)videoView
             hardwareDecoderReader:(nullable MPVClientHardwareDecoderReader)hardwareDecoderReader;
- (void)loadURL:(NSURL *)url loadID:(uint64_t)loadID;
- (void)loadURLUsingSoftwareDecoding:(NSURL *)url loadID:(uint64_t)loadID;
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
