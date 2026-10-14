const $ = (s) => document.querySelector(s);

function el(tag, props = {}, ...children) {
  const e = Object.assign(document.createElement(tag), props);
  e.append(...children);
  return e;
}

function toggleRow(opt) {
  const input = el("input", { type: "checkbox" });
  input.dataset.key = opt.key;
  return el("label", { className: "row" }, el("span", {}, opt.label), el("label", { className: "switch" }, input, el("span")));
}

function buildUI() {
  const groups = {};
  for (const opt of OPTIONS) {
    if (opt.key === "enabled") continue;
    (groups[opt.group] ??= []).push(opt);
  }
  for (const [name, opts] of Object.entries(groups)) {
    $("#groups").append(el("section", {}, el("h2", { textContent: name }), ...opts.map(toggleRow)));
  }
  document.querySelectorAll("input[data-key]").forEach((input) => {
    input.onchange = () => saveSettings({ [input.dataset.key]: input.checked });
  });
  document.querySelectorAll("[data-mode]").forEach((button) => {
    button.onclick = () => saveSettings({ layoutMode: button.dataset.mode });
  });
}

async function render() {
  const s = await loadSettings();
  document.body.classList.toggle("off", !s.enabled);
  document.querySelectorAll("input[data-key]").forEach((i) => { i.checked = !!s[i.dataset.key]; });
  document.querySelectorAll("[data-mode]").forEach((b) => {
    const on = b.dataset.mode === s.layoutMode;
    b.classList.toggle("active", on);
    b.setAttribute("aria-checked", String(on));
  });
}

buildUI();
// Always open at the top (Safari can restore or land on a scrolled position).
render().then(() => requestAnimationFrame(() => window.scrollTo(0, 0)));
api.storage.onChanged.addListener(render);
