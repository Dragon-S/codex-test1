# Mac App Store, licensing, and local-file constraints

Research date: 2026-07-31

## Decision

Preserve the Mac App Store path from the first internal build:

1. Enable App Sandbox now, with only user-selected read-only file access and app-scoped security-scoped bookmarks.
2. Enable Hardened Runtime as a best practice, even though Apple says it is not required for App Store apps. Keep library validation enabled.
3. Embed every native library, helper, and codec component in the signed app bundle. Do not download executable code, codecs, or plug-ins.
4. Put a narrow playback-engine protocol between product code and the implementation.
5. Start the MVP with Apple frameworks where they meet the verified format matrix. If broader decoding is required, prefer an audited, reproducible **LGPL-only dynamic build** of FFmpeg; evaluate LGPL-mode libmpv next. Do not ship GPL or `--enable-nonfree` components in the intended closed-source App Store build.
6. Treat codec-patent clearance as a separate release gate. An open-source license does not establish patent permission.

This is an engineering compliance posture, not legal advice. Before commercial distribution, counsel should review the exact binary dependency graph, storefronts, EULA, source-offer process, and codec/patent exposure.

## Non-negotiable Mac App Store constraints

### Sandbox and local files

Mac App Store apps must use App Sandbox. App Review Guidelines 2.4.5 additionally require appropriate sandboxing and the correct macOS file APIs; apps must be self-contained bundles and cannot install code or resources in shared locations. Guideline 2.5.2 prohibits reading or writing outside the designated container and downloading, installing, or executing code that changes functionality. [Apple: App Sandbox](https://developer.apple.com/documentation/security/app-sandbox) · [Apple: App Review Guidelines 2.4.5 and 2.5.2](https://developer.apple.com/app-store/review/guidelines/)

For this player, use `com.apple.security.files.user-selected.read-only`. A standard `NSOpenPanel` or SwiftUI file importer grants access to the selected URL; selecting a folder extends access recursively to its contents. Apple documents that URLs obtained through the standard panel begin security-scoped access and must later be balanced with `stopAccessingSecurityScopedResource()`. [Apple: Accessing files from the macOS App Sandbox](https://developer.apple.com/documentation/security/accessing-files-from-the-macos-app-sandbox)

Persisted playlists need app-scoped security-scoped bookmarks, not plain paths. Create bookmark data with security scope, store it in the app container, resolve it on launch, refresh stale bookmark data, call `startAccessingSecurityScopedResource()` before playback, and balance it with `stopAccessingSecurityScopedResource()` afterward. The corresponding entitlement is `com.apple.security.files.bookmarks.app-scope`. [Apple: Accessing files from the macOS App Sandbox](https://developer.apple.com/documentation/security/accessing-files-from-the-macos-app-sandbox) · [Apple: Enabling Security-Scoped Bookmark and URL Access](https://developer.apple.com/documentation/professional-video-applications/enabling-security-scoped-bookmark-and-url-access)

Design implications:

- Store bookmark data plus display metadata and a last-known path; the path is diagnostic/UI data, not authority.
- A bookmark resolution failure or inaccessible file becomes the product's existing “missing file” state.
- Folder import is authorized only for the user-selected folder. Persist the folder bookmark only if future rescans are a product feature; otherwise persist bookmarks for imported files.
- Prefer read-only access. Playback and metadata reading do not justify write access.
- Avoid temporary-exception entitlements. Apple requires each such exception to be explained in App Store Connect, and workarounds for missing sandbox features need a Feedback Assistant issue ID. [Apple: App Sandbox information](https://developer.apple.com/help/app-store-connect/reference/app-uploads/app-sandbox-information)

### Signing, Hardened Runtime, and native code

Apple says Hardened Runtime is not necessary for App Store apps but is best practice for new code. It is required for notarized Developer ID distribution. Enable it for the app and any executable helper during development so engine integration cannot silently depend on a runtime exception that later threatens distribution. [Apple: Embedding a command-line tool in a sandboxed app](https://developer.apple.com/documentation/xcode/embedding-a-helper-tool-in-a-sandboxed-app) · [Apple: Preparing your app for distribution](https://developer.apple.com/documentation/Xcode/preparing-your-app-for-distribution)

Hardened Runtime enables library validation by default: loaded frameworks, plug-ins, and libraries must be signed by Apple or with the app's Team ID. Do not request `com.apple.security.cs.disable-library-validation`; build and sign the shipped native dependencies as part of the product instead. [Apple: Disable Library Validation Entitlement](https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.security.cs.disable-library-validation)

Dynamic native libraries are not inherently forbidden. Apple documents `Contents/Frameworks` as the standard location for frameworks and dylibs and requires nested code to be signed before the outer app. Xcode's distribution workflow should re-sign embedded code with the product identity. [Apple: Code Signing Tasks — nested code](https://developer.apple.com/library/archive/documentation/Security/Conceptual/CodeSigningGuide/Procedures/Procedures.html) · [Apple: Creating distribution-signed code for macOS](https://developer.apple.com/documentation/xcode/creating-distribution-signed-code-for-the-mac/)

If a separate decoder/helper process is used, embed it in `Contents/MacOS`, sign it on copy, and make it inherit the containing app's sandbox with only `com.apple.security.app-sandbox` and `com.apple.security.inherit`. Apple notes that an XPC service is often preferable when separation is needed. [Apple: Embedding a command-line tool in a sandboxed app](https://developer.apple.com/documentation/xcode/embedding-a-helper-tool-in-a-sandboxed-app)

All decoder libraries, shader/code resources, and plug-ins required for reviewed functionality must ship inside the app bundle. The app must not fetch executable codec packs or update them independently; App Review Guidelines 2.4.5(iv) and 2.5.2 disallow that pattern. [Apple: App Review Guidelines](https://developer.apple.com/app-store/review/guidelines/)

## Open-source engine options

### FFmpeg

FFmpeg is LGPL 2.1-or-later by default, but optional GPL components make the whole FFmpeg build GPL, and `--enable-nonfree` can produce a binary that FFmpeg describes as unredistributable. FFmpeg itself recommends, for the straightforward LGPL compliance route, building without `--enable-gpl` and `--enable-nonfree`, dynamically linking, distributing the exact corresponding source and build information, crediting FFmpeg, permitting reverse engineering for LGPL debugging, and auditing every external library. It specifically identifies `libx264` as GPL. [FFmpeg: License and Legal Considerations](https://ffmpeg.org/legal.html) · [FFmpeg: License](https://ffmpeg.org/doxygen/trunk/md_LICENSE.html)

Recommended posture:

- Maintain a pinned, reproducible configure manifest and Software Bill of Materials.
- Build shared libraries for both target architectures with `--disable-gpl --disable-nonfree`.
- Audit the configure output and transitive libraries; a nominally LGPL FFmpeg build can change license through linked dependencies.
- Embed the dylibs in `Contents/Frameworks`, fix install names/rpaths, and let Xcode sign them with the app.
- Include license notices in-app and in the bundle, publish the exact corresponding source and patches, document the build, and ensure the product EULA does not prohibit the reverse engineering needed to debug modifications to the LGPL components.

Static linking is not automatically impossible under the LGPL, but it shifts the burden to supplying relinkable application material or another compliant mechanism. Dynamic linking is the upstream project's recommended and operationally safer posture for a proprietary app. [GNU: LGPL 2.1, section 6](https://www.gnu.org/licenses/old-licenses/lgpl-2.1.html) · [FFmpeg: License and Legal Considerations](https://ffmpeg.org/legal.html)

### libmpv / mpv

mpv is GPL 2-or-later by default. Upstream provides `-Dgpl=false` to exclude GPL-only files and describes LGPL mode as intended for libmpv, but explicitly warns that the build switch does not itself create a license grant and that linked libraries such as a GPL FFmpeg build can still affect the final binary's license. [mpv: README license summary](https://github.com/mpv-player/mpv#license) · [mpv: Copyright and LGPL build details](https://github.com/mpv-player/mpv/blob/master/Copyright)

libmpv is attractive as a complete playback engine, but its compliance surface is broader than direct FFmpeg because the exact mpv source set, FFmpeg build, renderer dependencies, subtitle libraries, and other transitive components must all be audited. Only consider a pinned `-Dgpl=false` libmpv build after proving the exact binary is LGPL-compatible and works in App Sandbox with Hardened Runtime and library validation intact.

### libVLC / VLCKit

VideoLAN describes libVLC as LGPL 2.1 and provides VLCKit for Apple platforms. It also describes libVLC as modularized into hundreds of plug-ins loaded at runtime. [VideoLAN: libVLC](https://www.videolan.org/vlc/libvlc.html) · [VLC source: COPYING](https://code.videolan.org/videolan/vlc/-/blob/master/COPYING)

The LGPL label alone is not sufficient for a shipping decision: audit the exact VLCKit/libVLC distribution and every included module. Its plug-in architecture also creates packaging work: all required modules must be bundled and signed at review time, load successfully with library validation enabled, and never be downloaded as codec extensions. It remains a viable fallback candidate, but has the largest bundle and plug-in audit surface of the three options considered here.

### GPL builds

A GPL build is not the recommended path for this product. GPL use would require the combined distributed work to meet the GPL's source and redistribution conditions; that conflicts with the intended proprietary/closed-source posture even before App Store contract analysis. Separately, App Review makes the developer responsible for third-party SDK compliance and requires rights to included intellectual property. [GNU: GPL 2.0](https://www.gnu.org/licenses/old-licenses/gpl-2.0.html) · [Apple: App Review Guidelines 5.2](https://developer.apple.com/app-store/review/guidelines/)

This report does not claim that GPL software is categorically barred from the Mac App Store. That conclusion depends on the exact GPL version, program structure, Apple agreement in force, and distribution model. If a GPL engine is ever proposed, treat it as a product-licensing decision requiring counsel and likely a source-distribution strategy, not as a build flag.

## Codec and patent boundary

Copyright license compliance does not settle patent rights. FFmpeg says it cannot determine whether its implementations practice patents and notes that H.264 and MPEG-4 standards warn that implementations may involve claimed patent rights. It also notes that patent treatment varies by jurisdiction and flags commercial products as the higher-risk case. [FFmpeg: Patent Mini-FAQ](https://ffmpeg.org/legal.html)

Apple's App Review Guidelines require the submitting entity to own or license relevant intellectual-property rights and specifically prohibit using patented ideas without permission. [Apple: App Review Guidelines 5.2](https://developer.apple.com/app-store/review/guidelines/)

Therefore:

- Do not describe any FFmpeg/libmpv/libVLC build as “patent cleared.”
- Before external/commercial release, produce a codec-by-codec and storefront-by-storefront review covering at least H.264/AVC, H.265/HEVC, AAC, MPEG-4 Part 2, Dolby-family formats, and any additional enabled encoders/decoders.
- Distinguish Apple's platform codec availability from a patent license for a separately shipped decoder. This research found no primary source establishing that bundling an independent implementation inherits Apple's licenses.
- Keep the MVP decoder list configurable at build time so legally uncertain components can be omitted without restructuring the app.

## Acceptance gates for the architecture decision

Before selecting a non-Apple engine for the product:

- Archive and export an App Store build with App Sandbox and Hardened Runtime enabled.
- Verify app, helpers, frameworks, and dylibs with `codesign`; verify no `disable-library-validation`, JIT, unsigned-executable-memory, or temporary-exception entitlement is present.
- Test open-panel import, folder import, relaunch bookmark resolution, stale bookmarks, moved/deleted files, and balanced security-scope access.
- Generate an SBOM from the actual release binaries and map every component to a license and source revision.
- Reproduce the binary from the recorded build configuration; publish corresponding LGPL source/patches and notices before external distribution.
- Verify there is no runtime download or discovery of executable codecs/plugins.
- Complete legal review of the final EULA, LGPL relinking/reverse-engineering terms, GPL absence, and codec/patent exposure.

## Bottom line

The App Store path is technically compatible with a broad local-file player, including embedded dynamic decoder libraries, if the product is sandbox-first, bookmark-based, self-contained, and fully signed. The lowest-risk route is Apple frameworks behind an engine boundary; when their format coverage is insufficient, an audited LGPL-only dynamic FFmpeg build is the most controlled next step. LGPL-mode libmpv is a stronger full-engine candidate but carries a wider transitive audit; libVLC/VLCKit adds a large plug-in packaging surface. GPL and `nonfree` builds should remain outside the intended proprietary App Store configuration.
