# Main playback and playlist prototype

> THROWAWAY PROTOTYPE — three variants of the macOS player main window,
> switchable via `?variant=`, on `/prototypes/main-playback-playlist/`.

Run from the repository root:

```sh
python3 -m http.server 4173
```

Then open:

<http://localhost:4173/prototypes/main-playback-playlist/?variant=A>

Use the floating switcher or the left/right arrow keys to compare:

- **A — Cinema + Queue**: playback is dominant; the current Playlist is a drawer.
- **B — Playlist Workspace**: named Playlists and their contents are always visible.
- **C — Native Compact**: a compact split inspired by native macOS media utilities.

This prototype is read-only and keeps state in memory. Buttons only simulate the
interactions needed to compare hierarchy.
