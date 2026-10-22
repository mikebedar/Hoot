// Runs inside YouTube's own page (manifest "world": "MAIN"), where the player's API is reachable;
// content.js runs in an isolated world and can't call it. It reads Hoot's state from the
// attributes content.js puts on <html>, so no messaging is needed.
//
// "Always use the highest quality": content.js stores YouTube's quality preference, but a video
// loaded in a background tab has already buffered a minute or more at low quality, and YouTube
// plays that out before switching up. Setting the quality through the player (as YouTube's own
// quality menu does) discards that buffer and switches right away.
(() => {
  if (window.__hootPage) return;
  window.__hootPage = true;

  const root = document.documentElement;
  root.setAttribute("data-hoot-page", "1"); // lets content.js and tests see this script is running

  const wanted = () => root.hasAttribute("data-ytf-enabled") && root.hasAttribute("data-ytf-max-quality");
  let forcedFor = ""; // once per video, so a quality picked by hand sticks for the rest of it

  function forceHighest() {
    if (!wanted() || document.hidden) return;
    const player = document.getElementById("movie_player");
    if (typeof player?.getAvailableQualityLevels !== "function") return;
    const best = player.getAvailableQualityLevels().find((q) => q !== "auto");
    const videoId = player.getVideoData?.().video_id;
    if (!best || !videoId) return;
    const key = `${videoId}:${best}`;
    if (forcedFor === key) return;
    forcedFor = key;
    // Always set it: after a background load the player already reports the best quality while
    // its buffer is still low quality, and setting it is what flushes that buffer.
    player.setPlaybackQualityRange(best, best);
  }

  // "playing" doesn't bubble, but capture-phase listeners on the document still see it.
  document.addEventListener("playing", forceHighest, true);
  document.addEventListener("visibilitychange", forceHighest);
  document.addEventListener("yt-navigate-finish", () => setTimeout(forceHighest, 500));
  new MutationObserver(forceHighest).observe(root, { attributes: true, attributeFilter: ["data-ytf-max-quality"] });
})();
