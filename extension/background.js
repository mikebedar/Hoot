// Non-persistent background script: wakes for install/update events and status messages.
const api = globalThis.browser ?? globalThis.chrome;

const YOUTUBE = ["*://www.youtube.com/*", "*://youtube.com/*"];

// When Hoot is installed, enabled or updated, Safari drops the old build's styles from tabs that
// are already open, and doesn't inject the new build until they reload. Re-apply Hoot to them now
// so nobody has to refresh.
api.runtime.onInstalled.addListener(async () => {
  const tabs = await api.tabs.query({ url: YOUTUBE });
  for (const tab of tabs) {
    try {
      await api.scripting.insertCSS({ target: { tabId: tab.id }, files: ["content.css"] });
      await api.scripting.executeScript({ target: { tabId: tab.id }, files: ["settings.js", "content.js"] });
    } catch {
      // Tab isn't scriptable right now (e.g. still loading or unloaded); it picks Hoot up on next load.
    }
  }
});

// The toolbar owl shows whether Hoot could lay out the current page (see the health check in content.js).
const ICONS = {
  ok: { 16: "icons/toolbar-16.png", 32: "icons/toolbar-32.png", 48: "icons/toolbar-48.png" },
  failed: { 16: "icons/toolbar-sad-16.png", 32: "icons/toolbar-sad-32.png", 48: "icons/toolbar-sad-48.png" },
};
const TITLES = {
  ok: "Hoot",
  failed: "Hoot couldn’t tidy this page, so YouTube’s normal layout is showing",
};

api.runtime.onMessage.addListener((msg, sender) => {
  if (msg?.type !== "hoot-status" || !sender.tab || !(msg.status in ICONS)) return;
  const tabId = sender.tab.id;
  api.action.setIcon({ tabId, path: ICONS[msg.status] });
  api.action.setTitle({ tabId, title: TITLES[msg.status] });
});
