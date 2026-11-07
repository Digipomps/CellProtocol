// ADJ_B render check: offline skeleton rendering with CellScaffold web runtime.
const path = require("node:path");
const fs = require("node:fs");
const REPO = "<HAVEN_ROOT>/CellScaffold";
const OUT = "<panel-arbeidsmappe>/out/render";
const { chromium } = require("/opt/node-tools/node_modules/playwright");
const publicDir = path.join(REPO, "Public");

function html(canvasClass) {
  return `<!doctype html><html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1">
<title>render</title><link rel="stylesheet" href="/css/porthole-webo.css"></head>
<body><main class="porthole-shell"><section class="${canvasClass}" id="canvas"><div id="root" class="skeleton-host"></div></section></main>
<script src="/js/skeleton-runtime.js"></script></body></html>`;
}

async function newPage(browser, canvasClass) {
  const page = await browser.newPage({ viewport: { width: 1180, height: 900 }, deviceScaleFactor: 1 });
  await page.route("**/*", async (route) => {
    const url = new URL(route.request().url());
    if (url.pathname === "/" ) return route.fulfill({ contentType: "text/html", body: html(canvasClass) });
    if (url.pathname === "/js/skeleton-runtime.js") return route.fulfill({ path: path.join(publicDir, "js", "skeleton-runtime.js"), contentType: "application/javascript" });
    if (url.pathname === "/css/porthole-webo.css") return route.fulfill({ path: path.join(publicDir, "css", "porthole-webo.css"), contentType: "text/css" });
    if (url.pathname.startsWith("/css/themes/")) {
      const f = path.join(publicDir, "css", "themes", decodeURIComponent(url.pathname.slice("/css/themes/".length)));
      if (fs.existsSync(f)) return route.fulfill({ path: f, contentType: "text/css" });
      return route.fulfill({ status: 404, body: "" });
    }
    return route.abort();
  });
  await page.goto("http://adj-b.test/");
  await page.waitForFunction(() => Boolean(window.HavenSkeletonRuntime?.createRenderer));
  return page;
}

const MEASURE = () => {
  function parse(c) { const m = c.match(/rgba?\(([^)]+)\)/); if (!m) return null; const p = m[1].split(",").map(Number); return { r: p[0], g: p[1], b: p[2], a: p.length > 3 ? p[3] : 1 }; }
  function lum({ r, g, b }) { const f = (v) => { v /= 255; return v <= 0.03928 ? v / 12.92 : Math.pow((v + 0.055) / 1.055, 2.4); }; return 0.2126 * f(r) + 0.7152 * f(g) + 0.0722 * f(b); }
  function contrast(a, b) { const l1 = lum(a), l2 = lum(b); return (Math.max(l1, l2) + 0.05) / (Math.min(l1, l2) + 0.05); }
  function effectiveBg(el) {
    let node = el;
    while (node && node !== document.documentElement) {
      const bg = getComputedStyle(node).backgroundColor; const p = parse(bg);
      if (p && p.a > 0) return { color: bg, from: node.className || node.tagName };
      const img = getComputedStyle(node).backgroundImage;
      if (img && img !== "none") return { color: "gradient:" + img.slice(0, 60), from: node.className || node.tagName, gradient: true };
      node = node.parentElement;
    }
    return { color: getComputedStyle(document.body).backgroundColor, from: "body" };
  }
  const texts = Array.from(document.querySelectorAll(".skeleton-text")).filter((t) => t.textContent.trim());
  const rows = texts.slice(0, 400).map((t) => {
    const fg = getComputedStyle(t).color; const bg = effectiveBg(t);
    const c = bg.gradient ? null : contrast(parse(fg), parse(bg.color));
    return { text: t.textContent.trim().slice(0, 50), fg, bg: bg.color, bgFrom: bg.from, contrast: c ? Number(c.toFixed(2)) : null };
  });
  return rows;
};

(async () => {
  const browser = await chromium.launch();
  const report = { c1: {}, c3: {}, c4: {} };

  // ---- C1: three Obsidian/Mermaid catalog surfaces
  const files = ["CellConfiguration.mermaid.playground.json", "CellConfiguration.obsidian-mermaid.staging.json", "CellConfiguration.vault.obsidian.json"];
  for (const file of files) {
    const cfg = JSON.parse(fs.readFileSync(path.join(REPO, "Documentation/ConfigurationCatalog", file), "utf8"));
    const name = cfg.name;
    report.c1[name] = {};
    for (const canvasClass of ["canvas view-mode", "canvas product-view view-mode", "canvas conference-view view-mode"]) {
      const page = await newPage(browser, canvasClass);
      // Porthole: theme <link> per configuration name (syncConfigurationTheme). Add it like Porthole would.
      await page.evaluate((n) => { const l = document.createElement("link"); l.rel = "stylesheet"; l.href = `/css/themes/${encodeURIComponent(n)}.css`; document.head.appendChild(l); }, name);
      const err = await page.evaluate((skeleton) => {
        try {
          window.__r = window.HavenSkeletonRuntime.createRenderer({ rootElement: document.getElementById("root"), skeleton, onAction: async () => {} });
          window.__r.update({});
          return null;
        } catch (e) { return String(e && e.message || e); }
      }, cfg.skeleton);
      const rows = await page.evaluate(MEASURE);
      const slug = `${file.replace(/\.json$/, "")}__${canvasClass.replace(/\s+/g, "_")}`;
      await page.screenshot({ path: path.join(OUT, slug + ".png"), fullPage: true });
      const contrasts = rows.map((r) => r.contrast).filter((c) => c != null);
      report.c1[name][canvasClass] = {
        renderError: err, textCount: rows.length,
        fgSet: [...new Set(rows.map((r) => r.fg))], bgSet: [...new Set(rows.map((r) => r.bg + " <- " + r.bgFrom))],
        minContrast: contrasts.length ? Math.min(...contrasts) : null, maxContrast: contrasts.length ? Math.max(...contrasts) : null,
        sample: rows.slice(0, 4),
      };
      await page.close();
    }
  }

  // ---- C3: Palazzo Gjest TextArea (submitActionKeypath + submitOnEnter) and parity Send button
  {
    const cfg = JSON.parse(fs.readFileSync(path.join(REPO, "Tests/AppTests/Fixtures/PortholeRemote/gjest-sicilia-liste.cellconfiguration.json"), "utf8"));
    const page = await newPage(browser, "canvas view-mode");
    const result = await page.evaluate(async (skeleton) => {
      window.__actions = [];
      const r = window.HavenSkeletonRuntime.createRenderer({ rootElement: document.getElementById("root"), skeleton, onAction: async (k, p, m) => { window.__actions.push({ keypath: k, payload: p, trigger: m && m.trigger }); } });
      r.update({});
      const ta = document.querySelector("textarea.skeleton-textarea");
      return { textareas: document.querySelectorAll("textarea").length, placeholder: ta && ta.placeholder, ariaLabel: ta && ta.getAttribute("aria-label"), labelledBy: ta && ta.labels ? ta.labels.length : null };
    }, cfg.skeleton);
    await page.fill("textarea.skeleton-textarea", "Bursdag, fire personer");
    await page.press("textarea.skeleton-textarea", "Enter");
    const actions = await page.evaluate(() => window.__actions);
    await page.screenshot({ path: path.join(OUT, "palazzo-gjest.png"), fullPage: true });
    report.c3.palazzoGjest = { ...result, actionsAfterEnter: actions };
    await page.close();

    const parity = JSON.parse(fs.readFileSync(path.join(REPO, "playwright/skeleton-scenarios/palazzo-communale-web.parity.skeleton.json"), "utf8"));
    const page2 = await newPage(browser, "canvas view-mode");
    await page2.evaluate((skeleton) => {
      window.__actions = [];
      const r = window.HavenSkeletonRuntime.createRenderer({ rootElement: document.getElementById("root"), skeleton, onAction: async (k, p, m) => { window.__actions.push({ keypath: k, payload: p, trigger: m && m.trigger }); } });
      r.update({});
    }, parity);
    await page2.fill("textarea.skeleton-textarea", "Hvilke retter uten melk?");
    await page2.getByRole("button", { name: "Send spørsmål →" }).click();
    const afterButton = await page2.evaluate(() => window.__actions.slice());
    await page2.press("textarea.skeleton-textarea", "Enter");
    const afterEnter = await page2.evaluate(() => window.__actions.slice());
    await page2.screenshot({ path: path.join(OUT, "palazzo-parity.png"), fullPage: true });
    report.c3.palazzoParity = { afterButton, afterEnter };
    await page2.close();
  }

  // ---- C4: control-tower Picker with selectionStateKeypath = action keypath; state as PortholeBootstrapProjection would deliver it
  {
    const cfg = JSON.parse(fs.readFileSync(path.join(REPO, "Documentation/ConfigurationCatalog/CellConfiguration.conference.control-tower.json"), "utf8"));
    // locate the "Access target" picker
    let picker = null;
    (function walk(n) { if (picker) return; if (Array.isArray(n)) return n.forEach(walk); if (n && typeof n === "object") { if (n.Picker && n.Picker.label === "Access target") { picker = n; return; } Object.values(n).forEach(walk); } })(cfg.skeleton);
    const page = await newPage(browser, "canvas view-mode");
    const res = await page.evaluate(async (pickerSpec) => {
      window.__actions = [];
      const r = window.HavenSkeletonRuntime.createRenderer({ rootElement: document.getElementById("root"), skeleton: { VStack: { elements: [pickerSpec] } }, onAction: async (k, p, m) => { window.__actions.push({ keypath: k, payload: p, trigger: m && m.trigger }); } });
      const options = [{ id: "seg-a", title: "Segment A" }, { id: "seg-b", title: "Segment B" }, { id: "seg-c", title: "Segment C" }];
      // (1) state WITHOUT the action keypath (what a projection without get-intercept would give)
      r.update({ conferenceAdminShell: { state: { accessRequests: { segmentOptions: options } } } });
      const sel = document.querySelector("select.skeleton-picker-select");
      const withoutState = { value: sel.value, text: sel.options[sel.selectedIndex] && sel.options[sel.selectedIndex].text };
      // (2) state WITH get-intercept value {selected: id} under the action keypath, as PortholeBootstrapProjection collects selectionStateKeypath
      r.update({ conferenceAdminShell: { state: { accessRequests: { segmentOptions: options } }, accessRequests: { selectSegment: { selected: "seg-b" } } } });
      const withState = { value: sel.value, text: sel.options[sel.selectedIndex] && sel.options[sel.selectedIndex].text };
      // (3) user picks C
      sel.value = "2"; sel.dispatchEvent(new Event("change", { bubbles: true }));
      await new Promise((res) => setTimeout(res, 50));
      const afterChange = { value: sel.value, actions: window.__actions.slice() };
      // (4) state refresh with unchanged selection → does the UI reset?
      r.update({ conferenceAdminShell: { state: { accessRequests: { segmentOptions: options } }, accessRequests: { selectSegment: { selected: "seg-b" } } } });
      const afterStaleRefresh = { value: sel.value };
      return { withoutState, withState, afterChange, afterStaleRefresh, optionLabelKeypath: pickerSpec.Picker.optionLabelKeypath };
    }, picker);
    await page.screenshot({ path: path.join(OUT, "control-tower-picker.png") });
    report.c4 = res;
    await page.close();
  }

  await browser.close();
  fs.writeFileSync(path.join(OUT, "render_report.json"), JSON.stringify(report, null, 2));
  console.log(JSON.stringify(report, null, 2));
})().catch((e) => { console.error(e); process.exit(1); });
