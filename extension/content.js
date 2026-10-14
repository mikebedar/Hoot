// Runs at document_start on every YouTube page. settings.js is loaded first.
// background.js may also inject it into already-open tabs after an install or update.
(() => {
  // After an update Safari can leave the previous copy of this script running in the same tab
  // environment. The newest copy takes over; older copies see they're superseded and go quiet.
  const instance = {};
  window.__hootInstance = instance;
  const current = () => window.__hootInstance === instance;

  const root = document.documentElement;
  // Which build is running in this tab (useful in bug reports and when testing updates).
  root.setAttribute("data-hoot-version", api.runtime.getManifest().version);
  let settings = { ...DEFAULTS };

  const kebab = (s) => s.replace(/[A-Z]/g, (c) => "-" + c.toLowerCase());
  const onWatchPage = () => location.pathname.startsWith("/watch");

  // ---------- Applying settings ----------

  function apply(runPageHooks = true) {
    if (!current()) return;
    for (const { key } of OPTIONS) {
      root.toggleAttribute(`data-ytf-${kebab(key)}`, !!settings[key]);
    }
    // In fullscreen, YouTube sizes the player itself; Hoot's layout rules stand down entirely
    // (the "hide X" rules, e.g. the fullscreen suggestion grid, stay on).
    const fullscreen = !!(document.fullscreenElement || document.webkitFullscreenElement);
    for (const key of LAYOUT_KEYS) {
      const off = fullscreen && FULLSCREEN_OFF_KEYS.includes(key);
      root.toggleAttribute(`data-ytf-${kebab(key)}`, !!settings.enabled && !off);
    }
    // Every rule in content.css requires data-ytf-enabled, so dropping it in fallback puts the page
    // back exactly as YouTube made it.
    if (fallback) root.removeAttribute("data-ytf-enabled");
    applyMode();

    // YouTube restores theater mode from this cookie on load, so set it before its scripts run.
    if (settings.enabled) {
      document.cookie = "wide=1; domain=.youtube.com; path=/; max-age=31536000";
    }

    if (runPageHooks) onPage();
  }

  // Layout mode ("default" or "fullframe"). Only set on video pages: Full Frame hides the header and
  // stops page scrolling, which must never leak onto the home page, search results, etc.
  function applyMode() {
    if (settings.enabled && onWatchPage()) root.setAttribute("data-ytf-mode", settings.layoutMode);
    else root.removeAttribute("data-ytf-mode");
  }

  // Default mode keeps the title row on screen under the video, so content.css needs its height,
  // which changes when a long title wraps. Measure it whenever it changes.
  let titleObserver = null;
  let observedTitle = null;
  function watchTitleRow() {
    const meta = document.querySelector("ytd-watch-flexy:not([hidden]) ytd-watch-metadata");
    if (!meta || meta === observedTitle) return !!meta;
    titleObserver?.disconnect();
    titleObserver = new ResizeObserver(([entry]) => {
      const h = Math.ceil(entry.borderBoxSize?.[0]?.blockSize ?? entry.target.offsetHeight);
      if (h > 0) root.style.setProperty("--ytf-title-h", `${h}px`); // 0 while hidden (Full Frame): keep the last value
    });
    titleObserver.observe(meta);
    observedTitle = meta;
    return true;
  }

  // ---------- Behaviours CSS can't do ----------

  // YouTube renders lazily; retry until `fn` reports success or we give up.
  function retry(fn, tries = 20, interval = 500) {
    if (fn() || tries <= 1) return;
    setTimeout(() => retry(fn, tries - 1, interval), interval);
  }

  let theaterClickedFor = null;

  function ensureTheater() {
    const flexy = document.querySelector("ytd-watch-flexy:not([hidden])");
    if (!flexy) return false;
    // In the 2026 redesign the size button toggles the side panels instead of theater
    // mode; the player is made full width by CSS there, so leave the button alone.
    if (flexy.matches("[fixed-default-panels], [show-fixed-side-menu]")) return true;
    if (flexy.hasAttribute("theater")) return true;
    // Several page events call this; only ever click once per video so we can't toggle it back off.
    const videoId = flexy.getAttribute("video-id");
    if (theaterClickedFor === videoId) return true;
    const btn = document.querySelector("#movie_player .ytp-size-button");
    if (!btn) return false;
    theaterClickedFor = videoId;
    btn.click();
    return true;
  }

  function ensureAutoplayOff() {
    const toggle = document.querySelector("#movie_player .ytp-autonav-toggle-button");
    if (!toggle) return false;
    if (toggle.getAttribute("aria-checked") === "true") toggle.closest("button")?.click();
    return true;
  }

  function ensureDescriptionExpanded() {
    const expander = document.querySelector(
      "ytd-watch-metadata ytd-text-inline-expander, [target-id='engagement-panel-structured-description'] ytd-text-inline-expander"
    );
    if (!expander) return false;
    if (expander.hasAttribute("is-expanded")) return true;
    const btn = expander.querySelector("#expand");
    if (!btn || !btn.offsetHeight) return false;
    btn.click();
    return true;
  }

  function onPage() {
    if (!current()) return;
    applyMode();
    scheduleCheck();
    if (!settings.enabled || !onWatchPage()) return;
    retry(watchTitleRow);
    retry(ensureTheater);
    if (settings.disableAutoplay) retry(ensureAutoplayOff);
    if (settings.expandDescription) retry(ensureDescriptionExpanded);
    // The player measures its container on resize; nudge it after layout changes.
    setTimeout(() => window.dispatchEvent(new Event("resize")), 300);
  }

  // ---------- Health check ----------
  // Hoot only rearranges pages it recognises. After each watch-page load, and after resizes,
  // check the result: the title row sits under the video, and in the redesign's two-column mode
  // the description panel does too. If that still isn't true after a few seconds (YouTube shipped
  // a layout we don't know), Hoot steps back completely on this page, so it looks exactly like
  // normal YouTube, and the toolbar shows the sad owl.

  let fallback = false;
  let reported = null;
  let checkTimer = null;

  function report(status) {
    if (status === reported) return;
    reported = status;
    try {
      api.runtime.sendMessage({ type: "hoot-status", status })?.catch?.(() => {});
    } catch {
      // Extension was reloaded under this page; the new instance reports instead.
    }
  }

  function shown(el) {
    if (!el) return false;
    if (el.checkVisibility && !el.checkVisibility({ opacityProperty: true, visibilityProperty: true })) return false;
    return el.getBoundingClientRect().height > 0;
  }

  function layoutLooksRight() {
    const flexy = document.querySelector("ytd-watch-flexy:not([hidden])");
    const player = document.querySelector("#movie_player");
    // Full Frame shows nothing but the video, so just check the video is there and visible.
    if (settings.layoutMode === "fullframe") return !!flexy && shown(player) && player.getBoundingClientRect().width > 200;
    const meta = flexy?.querySelector("ytd-watch-metadata");
    if (!flexy || !player || !shown(meta)) return false;
    const playerBottom = player.getBoundingClientRect().bottom - 1;
    if (meta.getBoundingClientRect().top < playerBottom) return false;
    if (flexy.matches("[fixed-default-panels], [show-fixed-side-menu]") && flexy.hasAttribute("is-two-columns_")) {
      const desc = flexy.querySelector('#secondary [target-id="engagement-panel-structured-description"]');
      if (!shown(desc) || desc.getBoundingClientRect().top < playerBottom) return false;
    }
    return true;
  }

  function scheduleCheck(delay = 400) {
    clearTimeout(checkTimer);
    let tries = 0;
    const run = () => {
      if (!current()) return;
      if (!settings.enabled || !location.pathname.startsWith("/watch")) return report("ok");
      if (fallback) return report("failed");
      if (document.fullscreenElement || document.webkitFullscreenElement) return; // checked again when fullscreen ends
      if (layoutLooksRight()) return report("ok");
      if (++tries < 16) {
        checkTimer = setTimeout(run, 500); // give YouTube ~8s to finish rendering
        return;
      }
      fallback = true;
      apply(false);
      report("failed");
    };
    checkTimer = setTimeout(run, delay);
  }

  let resizeTimer = null;
  window.addEventListener("resize", () => {
    clearTimeout(resizeTimer);
    resizeTimer = setTimeout(() => scheduleCheck(0), 800);
  });

  function onFullscreenChange() {
    if (!current()) return;
    apply(false);
    // Coming back from fullscreen, the player re-measures its container on resize.
    setTimeout(() => window.dispatchEvent(new Event("resize")), 300);
    scheduleCheck(800);
  }
  document.addEventListener("fullscreenchange", onFullscreenChange);
  document.addEventListener("webkitfullscreenchange", onFullscreenChange);

  // YouTube is a single-page app: these fire on every in-app navigation. A new page gets a fresh
  // chance at the full layout even if the previous one fell back.
  document.addEventListener("yt-navigate-finish", () => {
    if (!current()) return;
    if (fallback) {
      fallback = false;
      apply(false);
    }
    onPage();
  });
  document.addEventListener("yt-page-data-updated", onPage);

  // ---------- Boot ----------

  apply(false); // defaults immediately, so there's no flash of the full layout
  loadSettings().then((s) => {
    settings = s;
    apply();
  });
  api.storage.onChanged.addListener(async () => {
    settings = await loadSettings();
    apply();
  });
})();
