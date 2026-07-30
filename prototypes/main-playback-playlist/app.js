// THROWAWAY PROTOTYPE:
// Three variants of the player main window, switchable via ?variant=.

const variants = {
  A: "Cinema + Queue",
  B: "Playlist Workspace",
  C: "Native Compact",
};

const media = [
  { id: 1, title: "A Slow Arrival", kind: "video", duration: "42:16", meta: "2160p · HEVC", status: "ready" },
  { id: 2, title: "Night Ferry", kind: "audio", duration: "5:38", meta: "FLAC · 24-bit", status: "ready" },
  { id: 3, title: "The Long Way Home", kind: "video", duration: "1:48:07", meta: "1080p · H.264", status: "ready" },
  { id: 4, title: "Voice Memo — Pier 8", kind: "audio", duration: "2:11", meta: "M4A · AAC", status: "ready" },
  { id: 5, title: "Rough Cut 03", kind: "video", duration: "18:42", meta: "File missing", status: "missing" },
];

const state = {
  currentId: 1,
  playing: false,
  position: 38,
  volume: 74,
  playlist: "Weekend Review",
  subtitle: "English",
  audioTrack: "English 5.1",
  queueOpen: true,
};

const app = document.querySelector("#app");

function currentMedia() {
  return media.find((item) => item.id === state.currentId);
}

function icon(kind) {
  return kind === "video" ? "▰" : "♫";
}

function mediaRows(compact = false) {
  return media
    .map(
      (item, index) => `
        <button class="media-row ${item.id === state.currentId ? "selected" : ""} ${item.status === "missing" ? "missing" : ""}"
          data-action="select" data-id="${item.id}" aria-label="Play ${item.title}">
          <span class="row-index">${item.status === "missing" ? "!" : index + 1}</span>
          <span class="kind-icon">${icon(item.kind)}</span>
          <span class="row-copy">
            <strong>${item.title}</strong>
            <small>${item.meta}${compact ? "" : ` · ${item.duration}`}</small>
          </span>
          <span class="row-duration">${item.duration}</span>
          <span class="row-more">•••</span>
        </button>
      `,
    )
    .join("");
}

function poster(extraClass = "") {
  const item = currentMedia();
  const isAudio = item.kind === "audio";
  return `
    <section class="poster ${isAudio ? "audio-poster" : ""} ${extraClass}">
      <div class="poster-ambient"></div>
      ${
        isAudio
          ? `<div class="album-art"><span>♫</span></div>
             <div class="audio-title"><strong>${item.title}</strong><span>Weekend recordings</span></div>`
          : `<div class="film-frame">
              <span class="moon"></span>
              <span class="mountain mountain-one"></span>
              <span class="mountain mountain-two"></span>
              <span class="film-title">A SLOW ARRIVAL</span>
            </div>`
      }
      <button class="poster-play" data-action="toggle-play" aria-label="${state.playing ? "Pause" : "Play"}">
        ${state.playing ? "Ⅱ" : "▶"}
      </button>
      <span class="poster-badge">${isAudio ? "AUDIO" : "4K · HEVC"}</span>
    </section>
  `;
}

function scrubber() {
  return `
    <div class="scrubber">
      <span>16:03</span>
      <input data-action="position" type="range" min="0" max="100" value="${state.position}" aria-label="Playback position" />
      <span>−26:13</span>
    </div>
  `;
}

function transport({ expanded = false } = {}) {
  return `
    <section class="transport ${expanded ? "expanded" : ""}">
      ${scrubber()}
      <div class="transport-row">
        <button data-action="shuffle" aria-label="Shuffle">⌘</button>
        <button aria-label="Previous">◀◀</button>
        <button class="primary-play" data-action="toggle-play" aria-label="${state.playing ? "Pause" : "Play"}">
          ${state.playing ? "Ⅱ" : "▶"}
        </button>
        <button aria-label="Next">▶▶</button>
        <button data-action="repeat" aria-label="Repeat">↻</button>
        <span class="transport-spacer"></span>
        <label class="volume-control">◖
          <input data-action="volume" type="range" min="0" max="100" value="${state.volume}" aria-label="Volume" />
        </label>
        <select data-action="speed" aria-label="Playback speed">
          <option>1×</option><option>1.25×</option><option>1.5×</option><option>2×</option>
        </select>
        <button data-action="pip" aria-label="Picture in Picture">▣</button>
        <button data-action="fullscreen" aria-label="Fullscreen">⛶</button>
      </div>
    </section>
  `;
}

function trackMenus({ labels = true } = {}) {
  return `
    <label class="track-menu">${labels ? "<span>Audio</span>" : ""}
      <select data-action="audio-track" aria-label="Audio track">
        <option>English 5.1</option><option>Director commentary</option><option>日本語 Stereo</option>
      </select>
    </label>
    <label class="track-menu">${labels ? "<span>Subtitles</span>" : ""}
      <select data-action="subtitle" aria-label="Subtitles">
        <option>English</option><option>简体中文</option><option>Off</option>
      </select>
    </label>
  `;
}

function titlebar(label, trailing = "") {
  return `
    <header class="titlebar">
      <span class="traffic"><i></i><i></i><i></i></span>
      <strong>${label}</strong>
      <span class="titlebar-actions">${trailing}</span>
    </header>
  `;
}

function variantA() {
  return `
    <div class="window variant-a">
      ${titlebar("A Slow Arrival", `
        <button data-action="toggle-queue" aria-label="Toggle Playlist">☷</button>
      `)}
      <div class="cinema-shell">
        <div class="cinema-main">
          ${poster("cinema-poster")}
          <div class="cinema-now">
            <span><strong>${currentMedia().title}</strong><small>${state.playlist} · 1 of 5</small></span>
            <div class="inline-tracks">${trackMenus({ labels: false })}</div>
          </div>
          ${transport({ expanded: true })}
        </div>
        ${
          state.queueOpen
            ? `<aside class="queue-drawer">
                <div class="pane-heading">
                  <span><small>PLAYLIST</small><strong>${state.playlist}</strong></span>
                  <button aria-label="Playlist menu">•••</button>
                </div>
                <div class="media-list">${mediaRows()}</div>
                <button class="add-media">＋ Add Local Media</button>
              </aside>`
            : ""
        }
      </div>
    </div>
  `;
}

function variantB() {
  return `
    <div class="window variant-b">
      ${titlebar("Local Media", `
        <button aria-label="Search">⌕</button>
        <button aria-label="More">•••</button>
      `)}
      <div class="workspace-grid">
        <aside class="playlist-sidebar">
          <div class="sidebar-heading">PLAYLISTS <button aria-label="New Playlist">＋</button></div>
          <button><span>▣</span> Recently Played</button>
          <button class="active"><span>♫</span> Weekend Review <em>5</em></button>
          <button><span>♫</span> Ambient Work <em>18</em></button>
          <button><span>♫</span> Short Films <em>7</em></button>
          <button><span>♫</span> Language Practice <em>12</em></button>
          <div class="sidebar-footer">4 Playlists · 42 items</div>
        </aside>
        <section class="playlist-workspace">
          <div class="workspace-heading">
            <span><h1>${state.playlist}</h1><p>5 items · 2 hr 56 min</p></span>
            <button>＋ Add Local Media</button>
          </div>
          <div class="column-head"><span>#</span><span>Title</span><span>Format</span><span>Time</span></div>
          <div class="media-list table-list">${mediaRows(true)}</div>
        </section>
        <aside class="now-inspector">
          ${poster("inspector-poster")}
          <div class="inspector-copy">
            <small>NOW PLAYING</small>
            <h2>${currentMedia().title}</h2>
            <p>${currentMedia().meta}</p>
          </div>
          ${scrubber()}
          <div class="inspector-transport">
            <button>◀◀</button>
            <button class="primary-play" data-action="toggle-play">${state.playing ? "Ⅱ" : "▶"}</button>
            <button>▶▶</button>
          </div>
          <div class="inspector-settings">${trackMenus()}</div>
        </aside>
      </div>
      <footer class="workspace-footer">
        <span>♫ ${currentMedia().title}</span>
        <div><button data-action="toggle-play">${state.playing ? "Ⅱ" : "▶"}</button> Playing from ${state.playlist}</div>
        <label>◖ <input data-action="volume" type="range" value="${state.volume}" /></label>
      </footer>
    </div>
  `;
}

function variantC() {
  return `
    <div class="window variant-c">
      ${titlebar("", `
        <div class="segmented">
          <button class="active">Now Playing</button><button>Playlist</button>
        </div>
        <button aria-label="Search">⌕</button>
      `)}
      <div class="compact-stage">
        ${poster("compact-poster")}
        <section class="compact-info">
          <span class="eyebrow">NOW PLAYING · ${state.playlist.toUpperCase()}</span>
          <h1>${currentMedia().title}</h1>
          <p>${currentMedia().meta} · ${currentMedia().duration}</p>
          ${scrubber()}
          <div class="compact-transport">
            <button>◀◀</button>
            <button class="primary-play" data-action="toggle-play">${state.playing ? "Ⅱ" : "▶"}</button>
            <button>▶▶</button>
            <button>↻</button>
          </div>
          <div class="compact-tracks">${trackMenus()}</div>
        </section>
      </div>
      <section class="compact-playlist">
        <header>
          <span>
            <select aria-label="Choose Playlist"><option>${state.playlist}</option><option>Ambient Work</option></select>
            <small>5 Local Media · 2 hr 56 min</small>
          </span>
          <span><button>＋</button><button>•••</button></span>
        </header>
        <div class="media-list">${mediaRows(true)}</div>
      </section>
      <footer class="compact-footer">
        <span>5 items</span>
        <label>Volume <input data-action="volume" type="range" value="${state.volume}" /></label>
      </footer>
    </div>
  `;
}

function stateInspector() {
  return `
    <details class="state-inspector">
      <summary>Prototype state</summary>
      <pre>${JSON.stringify(
        {
          current: currentMedia().title,
          kind: currentMedia().kind,
          playing: state.playing,
          playlist: state.playlist,
          subtitle: state.subtitle,
          audioTrack: state.audioTrack,
          missingFile: media.find((item) => item.status === "missing").title,
        },
        null,
        2,
      )}</pre>
    </details>
  `;
}

function switcher(variant) {
  return `
    <nav class="prototype-switcher" aria-label="Prototype variants">
      <button data-action="previous-variant" aria-label="Previous variant">←</button>
      <span><small>THROWAWAY PROTOTYPE</small><strong>${variant} — ${variants[variant]}</strong></span>
      <button data-action="next-variant" aria-label="Next variant">→</button>
    </nav>
  `;
}

function missingDialog(item) {
  return `
    <div class="modal-backdrop">
      <section class="missing-dialog" role="dialog" aria-modal="true" aria-labelledby="missing-title">
        <span class="missing-icon">!</span>
        <h2 id="missing-title">“${item.title}” can’t be found</h2>
        <p>The Playlist still remembers this Local Media. Locate it on this Mac or remove it from the Playlist.</p>
        <div><button data-action="dismiss-modal">Cancel</button><button>Remove</button><button class="accent" data-action="locate">Locate…</button></div>
      </section>
    </div>
  `;
}

function getVariant() {
  const key = new URLSearchParams(location.search).get("variant")?.toUpperCase();
  return variants[key] ? key : "A";
}

function setVariant(next) {
  const url = new URL(location.href);
  url.searchParams.set("variant", next);
  history.replaceState({}, "", url);
  render();
}

function cycleVariant(direction) {
  const keys = Object.keys(variants);
  const currentIndex = keys.indexOf(getVariant());
  setVariant(keys[(currentIndex + direction + keys.length) % keys.length]);
}

function render(modal = "") {
  const variant = getVariant();
  const renderVariant = { A: variantA, B: variantB, C: variantC }[variant];
  app.innerHTML = `${renderVariant()}${stateInspector()}${switcher(variant)}${modal}`;
}

app.addEventListener("click", (event) => {
  const target = event.target.closest("[data-action]");
  if (!target) return;
  const action = target.dataset.action;

  if (action === "toggle-play") state.playing = !state.playing;
  if (action === "toggle-queue") state.queueOpen = !state.queueOpen;
  if (action === "previous-variant") return cycleVariant(-1);
  if (action === "next-variant") return cycleVariant(1);
  if (action === "dismiss-modal") return render();
  if (action === "locate") return render();
  if (action === "select") {
    const item = media.find((entry) => entry.id === Number(target.dataset.id));
    if (item.status === "missing") return render(missingDialog(item));
    state.currentId = item.id;
    state.playing = true;
  }
  render();
});

app.addEventListener("input", (event) => {
  if (event.target.dataset.action === "position") state.position = Number(event.target.value);
  if (event.target.dataset.action === "volume") state.volume = Number(event.target.value);
});

app.addEventListener("change", (event) => {
  if (event.target.dataset.action === "subtitle") state.subtitle = event.target.value;
  if (event.target.dataset.action === "audio-track") state.audioTrack = event.target.value;
  render();
});

window.addEventListener("keydown", (event) => {
  const tag = document.activeElement?.tagName;
  if (["INPUT", "TEXTAREA", "SELECT"].includes(tag) || document.activeElement?.isContentEditable) return;
  if (event.key === "ArrowLeft") cycleVariant(-1);
  if (event.key === "ArrowRight") cycleVariant(1);
  if (event.code === "Space") {
    event.preventDefault();
    state.playing = !state.playing;
    render();
  }
});

window.addEventListener("popstate", render);
render();
