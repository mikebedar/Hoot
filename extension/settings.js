// Shared by the content script and the popup. Top-level names use `var` because after an update
// Safari can run this file again in the same tab environment, and `const` can't be redeclared.
var api = globalThis.browser ?? globalThis.chrome;

// Hoot enforces one layout. These parts of it are always on while Hoot is enabled; each maps
// to a `data-ytf-<key>` attribute on <html> that content.css keys off.
var LAYOUT_KEYS = [
  "focusLayout",       // single column: video, then title/description/comments
  "fullWidthPlayer",   // full-width video
  "fitPlayerToScreen", // video sized to the window
  "hideRelated",       // suggested / related videos
  "hideShelves",       // merch, tickets, promo shelves
  "hideEndscreen",     // end-screen and pause-screen suggestions
  "hideInfoCards",     // info cards, suggested actions
];

// Layout rules that stand down while the video is fullscreen.
var FULLSCREEN_OFF_KEYS = ["focusLayout", "fullWidthPlayer", "fitPlayerToScreen"];

// The few things people genuinely disagree on get a switch in the popup.
var OPTIONS = [
  { key: "enabled",           label: "Enable Hoot",                     group: "General" },

  { key: "hideComments",      label: "Hide comments",                   group: "Watch page" },
  { key: "hideChat",          label: "Hide live chat & Ask (AI)",       group: "Watch page" },
  { key: "expandDescription", label: "Auto-expand description",         group: "Watch page" },
  { key: "disableAutoplay",   label: "Turn off autoplay-next",          group: "Watch page" },
  { key: "hideAmbient",       label: "Turn off ambient glow",           group: "Watch page" },

  { key: "hideShorts",        label: "Hide Shorts everywhere",          group: "Site-wide" },
  { key: "hideHomeFeed",      label: "Hide home page feed",             group: "Site-wide" },
  { key: "hideGuide",         label: "Hide left navigation sidebar",    group: "Site-wide" },
];

var DEFAULTS = {
  enabled: true,
  hideComments: false, hideChat: true, expandDescription: false, disableAutoplay: true, hideAmbient: true,
  hideShorts: true, hideHomeFeed: false, hideGuide: false,
};

async function loadSettings() {
  const stored = await api.storage.local.get(null);
  return { ...DEFAULTS, ...stored };
}

function saveSettings(patch) {
  return api.storage.local.set(patch);
}
