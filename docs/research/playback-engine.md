# Playback engine and codec strategy

Research date: 2026-07-31  
Decision ticket: [Evaluate the playback engine and codec strategy](https://github.com/Dragon-S/codex-test1/issues/2)

## Recommendation

Use **libmpv as the single playback engine**, embedded behind an app-owned Swift `PlaybackEngine` boundary. Build and redistribute an explicitly audited **LGPL-only** dependency set: mpv with `-Dgpl=false`, FFmpeg without `--enable-gpl` or `--enable-nonfree`, and only license-compatible optional libraries. Keep playlist persistence, file access, menus, media keys, localization, and window state in native Swift/AppKit code.

This is the best fit for the stated destination:

- mpv is designed to be embedded through libmpv, and its client API exposes commands, properties, events, and a render API rather than forcing the app to automate a standalone player process ([mpv manual](https://mpv.io/manual/stable/#using-mpv-from-other-programs-or-scripts), [official render example](https://github.com/mpv-player/mpv-examples/blob/master/libmpv/sdl/main.c)).
- mpv delegates broad demuxing/decoding to FFmpeg and exposes subtitle selection/rendering, high-resolution seeks, playback-speed control, frame stepping, filters, and GPU render controls through one engine API ([mpv manual: seeking](https://mpv.io/manual/stable/#options-hr-seek), [mpv manual: commands](https://mpv.io/manual/stable/#list-of-input-commands), [mpv manual: subtitles](https://mpv.io/manual/stable/#subtitles), [mpv manual: video filters](https://mpv.io/manual/stable/#video-filters)).
- On macOS, mpv lists VideoToolbox as an actively supported hardware-decoding path. Hardware decoding is opt-in and falls back to software when unavailable, so the exact policy must be tested against the target corpus and hardware ([mpv manual: hardware decoding](https://mpv.io/manual/stable/#hardware-decoding)).
- mpv supports an LGPL build, but it is GPL by default. FFmpeg is LGPL by default but becomes GPL when GPL components are enabled; its upstream compliance guidance explicitly calls for disabling GPL and nonfree components and tracking the exact build configuration ([mpv upstream README](https://github.com/mpv-player/mpv#license), [FFmpeg legal guidance](https://ffmpeg.org/legal.html)).

Do **not** build a player directly on FFmpeg libraries for the MVP. FFmpeg supplies codecs, demuxers, filters, and hardware-acceleration plumbing, but the product would still need to implement clocks, A/V synchronization, buffering, seeking semantics, track switching, subtitle composition, and rendering coordination. libmpv already provides that player layer while retaining access to FFmpeg-backed breadth.

The recommendation is conditional on two short prototypes:

1. Native macOS Picture in Picture from libmpv output.
2. Sandboxed/App Store packaging of the exact LGPL-only universal binary and its dynamically replaceable libraries.

If the Picture in Picture prototype cannot provide acceptable quality and control behavior, evaluate **VLCKit as the fallback**, not a dual AVFoundation/libmpv runtime. VLCKit has an Apple-platform binding and its recent upstream release notes claim macOS Picture in Picture support, but its stable engine is still LibVLC 3 while LibVLC 4 remains a development line ([VLCKit project](https://code.videolan.org/videolan/VLCKit), [VLCKit tags](https://code.videolan.org/videolan/VLCKit/-/tags), [LibVLC overview](https://www.videolan.org/vlc/libvlc.html)).

## Decision matrix

Ratings are relative to this product, not general framework quality.

| Criterion | AVFoundation / AVKit | libmpv + FFmpeg | LibVLC / VLCKit |
| --- | --- | --- | --- |
| Container and codec coverage | **Low–medium.** Apple presents AVFoundation as an easy path for QuickTime and MPEG-4 playback and lets an app query the types/codecs understood by `AVURLAsset`; that is not a promise of MKV or broad legacy-format coverage ([Apple AVFoundation overview](https://developer.apple.com/av-foundation/), [`AVURLAsset.audiovisualContentTypes`](https://developer.apple.com/documentation/avfoundation/avurlasset/audiovisualcontenttypes)). | **High.** mpv states broad file/codec/subtitle support and is built around FFmpeg; the exact shipped matrix depends on the chosen build flags and optional libraries ([mpv upstream README](https://github.com/mpv-player/mpv), [FFmpeg general documentation](https://ffmpeg.org/documentation.html)). | **High.** VideoLAN lists MKV, MP4/MOV, FLAC, H.264, AAC, SSA, and SubRip among VLC’s supported formats ([VLC features](https://www.videolan.org/vlc/features.html)). |
| Subtitle and multi-track support | **Medium.** AVFoundation has media-selection APIs and AVKit displays supported subtitles/closed captions, but ASS/SSA parity and styling are not promised by the cited APIs ([Apple: selecting subtitles and audio tracks](https://developer.apple.com/documentation/avfoundation/selecting-subtitles-and-alternative-audio-tracks), [AVKit](https://developer.apple.com/documentation/avkit)). | **High.** mpv exposes subtitle track selection, external subtitle loading, delay, position, styling, embedded fonts, and libass-backed ASS behavior ([mpv manual: subtitles](https://mpv.io/manual/stable/#subtitles)). | **High.** VLC lists SubRip and SSA subtitle support and LibVLC exposes track/player APIs ([VLC features](https://www.videolan.org/vlc/features.html), [LibVLC media player API](https://videolan.videolan.me/vlc/master/group__libvlc__media__player.html)). |
| Hardware decoding | **High / lowest integration risk.** AVFoundation is Apple’s native high-performance playback stack and integrates with VideoToolbox and platform HDR behavior ([Apple video overview](https://developer.apple.com/documentation/technologyoverviews/video), [Apple Dolby Vision playback note](https://developer.apple.com/av-foundation/Incorporating-HDR-video-with-Dolby-Vision-into-your-apps.pdf)). | **High, configuration-sensitive.** VideoToolbox is actively supported, with software fallback; upstream recommends testing `hwdec=auto` against representative content ([mpv manual: hardware decoding](https://mpv.io/manual/stable/#hardware-decoding)). | **High, configuration-sensitive.** VideoLAN states that VLC supports hardware decoding and software fallback; actual macOS zero-copy/HDR behavior needs measurement in the chosen VLCKit build ([VLC features](https://www.videolan.org/vlc/features.html)). |
| Seek behavior | **High for Apple-supported media.** `AVPlayerItem` exposes seekable ranges and time-based playback state, but corpus-specific precision and latency remain empirical ([`AVPlayerItem`](https://developer.apple.com/documentation/avfoundation/avplayeritem)). | **High / tunable.** mpv distinguishes keyframe and high-resolution seeks, documents the decode cost of precise seeks, and exposes exact-seek and frame-step commands ([mpv manual: `hr-seek`](https://mpv.io/manual/stable/#options-hr-seek), [mpv manual: `frame-step`](https://mpv.io/manual/stable/#command-interface-frame-step)). | **Medium–high.** LibVLC exposes time, position, chapter, rate, and next-frame controls, but precision and latency across the corpus require a prototype ([LibVLC media player API](https://videolan.videolan.me/vlc/master/group__libvlc__media__player.html)). |
| Native Picture in Picture | **High / direct.** AVKit accepts `AVPlayerLayer` directly and provides system PiP controls ([`AVPictureInPictureController`](https://developer.apple.com/documentation/avkit/avpictureinpicturecontroller)). | **Unknown / highest product risk.** Apple also accepts an `AVSampleBufferDisplayLayer`, so a custom-engine bridge is architecturally possible, but libmpv does not provide a documented AVKit adapter; frame transfer, timing, audio continuity, controls, HDR, and power use must be prototyped ([Apple PiP content source](https://developer.apple.com/documentation/avkit/avpictureinpicturecontroller/contentsource-swift.class)). | **Medium–high, verify.** VLCKit’s upstream release history reports Picture in Picture on iOS and macOS, but behavior on macOS 14+ with local files and the intended custom UI must be tested ([VLCKit tags](https://code.videolan.org/videolan/VLCKit/-/tags)). |
| Swift/AppKit integration | **High.** Native Swift/Objective-C frameworks, `AVPlayerView`, and `AVPlayerLayer` are directly available ([`AVPlayerView`](https://developer.apple.com/documentation/avkit/avplayerview), [`AVPlayer`](https://developer.apple.com/documentation/avfoundation/avplayer)). | **Medium.** libmpv is a C API with explicit event/render-loop and threading contracts; the app needs a thin Swift/C or Objective-C bridge and owns rendering integration ([mpv manual: embedding](https://mpv.io/manual/stable/#embedding-into-other-programs-libmpv), [official libmpv example](https://github.com/mpv-player/mpv-examples/blob/master/libmpv/sdl/main.c)). | **Medium–high.** VLCKit is the upstream Objective-C binding for Apple platforms and LibVLC can render into an `NSView`/NSObject drawable ([VLCKit project](https://code.videolan.org/videolan/VLCKit), [`libvlc_media_player_set_nsobject`](https://videolan.videolan.me/vlc/master/group__libvlc__media__player.html)). |
| Binary size | **Best.** No bundled third-party playback engine; exact app size still depends on app assets. | **Largest-risk tier.** mpv plus FFmpeg, libass, and selected dependencies are bundled. Exact universal-binary size is build-dependent and must be measured. | **Largest-risk tier.** VLCKit bundles LibVLC and plugins. Exact universal-binary size is build-dependent and must be measured. |
| Maintenance and updates | **Best operationally.** Apple ships the frameworks with macOS, so app-owned codec binaries do not need patching; behavior can still change with OS releases. | **High app-owned burden.** mpv says only the newest release is supported and older releases receive no maintenance except security fixes; FFmpeg maintains active security advisories. The app must pin, rebuild, regression-test, and redistribute updates ([mpv release policy summary](https://github.com/mpv-player/mpv#release-cycle), [FFmpeg security page](https://ffmpeg.org/security.html), [FFmpeg downloads/releases](https://ffmpeg.org/download.html)). | **High app-owned burden.** LibVLC/VLCKit and their plugin tree ship with the app. LibVLC 3 is stable while 4 is a development line, making the eventual major-version migration a planning concern ([LibVLC overview](https://www.videolan.org/vlc/libvlc.html), [VLCKit tags](https://code.videolan.org/videolan/VLCKit/-/tags)). |
| Future professional controls | **Medium.** AVFoundation exposes decoded video frames and supports custom video composition, which is a strong native base, but broad-format support remains the limiting factor ([`AVPlayerItemVideoOutput`](https://developer.apple.com/documentation/avfoundation/avplayeritemvideooutput), [`AVPlayerItem`](https://developer.apple.com/documentation/avfoundation/avplayeritem)). | **Best fit.** The API already exposes frame stepping, exact seeks, speed, subtitle timing, audio/video filters, shaders, screenshots, and observable playback properties; correctness of reverse stepping, waveform extraction, and color-managed output still needs dedicated design and tests ([mpv manual](https://mpv.io/manual/stable/)). | **Medium–high.** LibVLC exposes next-frame, rate, track, callback, and video-output APIs, but its surface is less directly aligned with mpv’s documented filter/shader/property model ([LibVLC media player API](https://videolan.videolan.me/vlc/master/group__libvlc__media__player.html)). |

## Why not the alternatives

### AVFoundation-only

AVFoundation/AVKit would minimize integration, binary, energy, and system-UI risk. It is the strongest choice if the product narrows its compatibility promise to Apple-supported containers/codecs. That conflicts with the agreed MVP target of MKV plus ASS/SSA and the longer-term goal of broad local-media compatibility. Apple provides runtime queries for understood file/content types rather than a stable promise that the desired third-party-format matrix is supported ([`AVURLAsset`](https://developer.apple.com/documentation/avfoundation/avurlasset)).

A hybrid “AVFoundation when possible, libmpv otherwise” is not recommended for MVP. It would duplicate playback state machines and create user-visible differences in seeking, subtitle selection, speed, resume state, color, audio routing, and PiP. A single engine behind a stable application boundary is easier to specify and test.

### LibVLC / VLCKit

LibVLC is a credible fallback: it has broad format coverage, an official Apple binding, an `NSView` rendering path, and an LGPL engine that permits differently licensed host applications ([LibVLC documentation](https://videolan.videolan.me/vlc/master/libvlc.html), [VLCKit project](https://code.videolan.org/videolan/VLCKit)). Its main disadvantages for this product are:

- stable LibVLC remains version 3 while version 4 is still preview/development, so adopting today also adopts a future major migration ([LibVLC overview](https://www.videolan.org/vlc/libvlc.html));
- some plugins can carry stronger GPL terms, so a shipped plugin set still requires a component-by-component audit ([LibVLC documentation](https://videolan.videolan.me/vlc/master/libvlc.html));
- mpv’s public command/property/filter model more directly covers the planned exact-seek, frame-step, subtitle timing, shader, and future professional-control seams ([mpv manual](https://mpv.io/manual/stable/)).

## Required architecture boundary

The app should depend on a product-level interface, not mpv symbols:

```text
PlaybackEngine
├── load(fileReference)
├── play / pause / stop
├── seek(time, precision)
├── step(frames)
├── rate / volume / mute
├── select(audioTrack / subtitleTrack)
├── loadExternalSubtitle(fileReference)
├── observe(state / time / duration / tracks / metadata / error)
└── attachVideoSurface(surface)
```

`LibMPVPlaybackEngine` owns the C handle, render context, event loop, and translation from mpv properties/events into app-domain values. The playlist is an app concern; do not expose mpv’s playlist as the persistence model. PiP should be a separate capability (`PictureInPictureProvider`) so its prototype can evolve without contaminating the basic playback contract.

## Prototype-dependent unknowns

These facts cannot be responsibly resolved from documentation alone:

1. **PiP bridge:** whether libmpv-rendered frames can be delivered through `AVSampleBufferDisplayLayer` with correct timing, system controls, audio continuity, HDR/SDR color, subtitle composition, and acceptable CPU/GPU use.
2. **Representative corpus:** success rate for MP4, MOV, MKV, MP3, AAC, FLAC, WAV, H.264, HEVC, SRT, and ASS/SSA combinations; malformed and unusual files must be included.
3. **Seek UX:** latency and accuracy for 10-second jumps, timeline scrubbing, exact seeks, forward frame step, and backward frame step across long-GOP, VFR, audio-only, and subtitle-heavy files.
4. **Hardware-decoding policy:** VideoToolbox codec/profile coverage, fallback behavior, energy use, dropped frames, 4K/8K performance, HDR metadata, and external-display behavior on representative Intel and Apple Silicon Macs.
5. **Color pipeline:** SDR/HDR color correctness through the selected render API, display changes, screenshots, and future color controls.
6. **Binary/package cost:** signed universal-app size for the exact LGPL-only build, launch time, memory footprint, and whether dependencies can be packaged in a form acceptable to sandboxing, notarization, and Mac App Store review.
7. **License manifest:** final transitive dependency and plugin list, build flags, relinking/replacement mechanism, notices, exact corresponding source archive, and codec-patent review. Upstream license pages are guidance, not legal advice ([FFmpeg legal guidance](https://ffmpeg.org/legal.html), [LibVLC licensing](https://videolan.videolan.me/vlc/master/libvlc.html)).
8. **Update SLA:** how quickly a new mpv/FFmpeg security release can be rebuilt, corpus-tested, and shipped. FFmpeg’s advisory history confirms that codec parsing is an active security-maintenance surface ([FFmpeg security](https://ffmpeg.org/security.html)).

## Proposed acceptance gates

Proceed with libmpv only if the prototypes demonstrate:

- all agreed MVP format/codec/subtitle combinations either play correctly or fail with an actionable error;
- hardware decoding has a documented default/fallback policy and meets playback/energy targets on the chosen device matrix;
- seek, scrub, speed, audio/subtitle switching, and resume behavior are stable;
- PiP meets the native macOS behavior expected for the MVP, or product scope explicitly defers PiP;
- the complete binary can be reproduced from pinned sources with an audited LGPL-only manifest and an App Store-compatible packaging path;
- the universal build’s size and memory costs fit targets established by the product specification.

Until those gates pass, `libmpv` is the **selected strategy for planning**, not yet a production-qualified dependency.
