// SPDX-License-Identifier: Apache-2.0
// Builds and checks the RichTextDelta fixture corpus against the Quill bundle
// the web document adapter loads (CellScaffold Public/vendor/quill/quill.js).
//
//   node vectors.js <path/to/quill.js> write   # (re)generate expected values
//   node vectors.js <path/to/quill.js> check   # fail if Quill disagrees
//
// Needs Playwright (Chromium); Quill needs a DOM to load.
const fs = require("fs");
const path = require("path");
const { chromium } = require("playwright");

const [quillPath, mode = "check"] = process.argv.slice(2);
if (!quillPath) { console.error("usage: node vectors.js <quill.js> write|check"); process.exit(2); }
const corpusPath = path.resolve(__dirname, "../../CellBaseTests/Fixtures/RichTextDeltaVectors.v1.json");

// Hand-written cases: the shapes the editor and the cell produce.
const handCases = [
  { name: "compose insert into empty", kind: "compose", a: [{ insert: "\n" }], b: [{ insert: "Hei" }] },
  { name: "compose typing after text", kind: "compose", a: [{ insert: "Hei\n" }], b: [{ retain: 3 }, { insert: " du" }] },
  { name: "compose bold over range", kind: "compose", a: [{ insert: "Hei du\n" }], b: [{ retain: 4 }, { retain: 2, attributes: { bold: true } }] },
  { name: "compose remove bold with null", kind: "compose", a: [{ insert: "Hei", attributes: { bold: true } }, { insert: "\n" }], b: [{ retain: 3, attributes: { bold: null } }] },
  { name: "compose header on line", kind: "compose", a: [{ insert: "Tittel\nTekst\n" }], b: [{ retain: 6 }, { retain: 1, attributes: { header: 1 } }] },
  { name: "compose delete across attribute runs", kind: "compose", a: [{ insert: "ab" }, { insert: "cd", attributes: { italic: true } }, { insert: "ef\n" }], b: [{ retain: 1 }, { delete: 4 }] },
  { name: "compose insert embed", kind: "compose", a: [{ insert: "Før\n" }], b: [{ retain: 4 }, { insert: { image: "data:image/png;base64,iVBORw0KGgo=" } }] },
  { name: "compose delete embed", kind: "compose", a: [{ insert: "a" }, { insert: { visualization: { kind: "chart", spec: { title: "T", rows: [{ id: "0", label: "x", value: 1 }] } } } }, { insert: "b\n" }], b: [{ retain: 1 }, { delete: 1 }] },
  { name: "compose emoji", kind: "compose", a: [{ insert: "Hei 😀 du\n" }], b: [{ retain: 4 }, { delete: 2 }, { insert: "🎉" }] },
  { name: "compose insert then delete", kind: "compose", a: [{ insert: "abc" }], b: [{ delete: 1 }, { retain: 1 }, { insert: "x" }] },
  { name: "compose list and link", kind: "compose", a: [{ insert: "en\nto\n" }], b: [{ retain: 2 }, { retain: 1, attributes: { list: "bullet" } }, { retain: 2, attributes: { link: "https://uio.no" } }] },
  { name: "transform both insert same place, priority", kind: "transform", a: [{ retain: 2 }, { insert: "A" }], b: [{ retain: 2 }, { insert: "B" }], priority: true },
  { name: "transform both insert same place, no priority", kind: "transform", a: [{ retain: 2 }, { insert: "A" }], b: [{ retain: 2 }, { insert: "B" }], priority: false },
  { name: "transform insert vs delete", kind: "transform", a: [{ retain: 1 }, { delete: 3 }], b: [{ retain: 2 }, { insert: "X" }], priority: true },
  { name: "transform delete vs delete overlap", kind: "transform", a: [{ retain: 1 }, { delete: 3 }], b: [{ retain: 2 }, { delete: 3 }], priority: false },
  { name: "transform attributes conflict, priority", kind: "transform", a: [{ retain: 3, attributes: { bold: true, italic: true } }], b: [{ retain: 3, attributes: { bold: false, underline: true } }], priority: true },
  { name: "transform attributes conflict, no priority", kind: "transform", a: [{ retain: 3, attributes: { bold: true } }], b: [{ retain: 3, attributes: { bold: false } }], priority: false },
  { name: "transform emoji delete vs insert", kind: "transform", a: [{ retain: 4 }, { delete: 2 }], b: [{ retain: 6 }, { insert: "!" }], priority: false },
  { name: "position after insert before", kind: "position", a: [{ insert: "ab" }], index: 0, priority: false },
  { name: "position after insert before, priority", kind: "position", a: [{ insert: "ab" }], index: 0, priority: true },
  { name: "position inside delete", kind: "position", a: [{ retain: 2 }, { delete: 5 }], index: 4, priority: false },
  { name: "position after delete", kind: "position", a: [{ retain: 2 }, { delete: 5 }], index: 9, priority: false },
  { name: "position before change", kind: "position", a: [{ retain: 5 }, { insert: "xyz" }], index: 3, priority: false },
];

// Seeded random cases on documents with emoji and embeds, so splitting and
// merging are exercised. Positions never fall inside a surrogate pair.
function rng(seed) { return () => { seed = (seed * 1103515245 + 12345) & 0x7fffffff; return seed / 0x7fffffff; }; }
const words = ["Hei", " ", "studenter", "\n", "😀", "æøå", "personvern", "\n", " og ", "🎉🎉", "data"];
const attrSets = [undefined, { bold: true }, { italic: true }, { bold: true, italic: true }, { link: "https://example.org" }, { underline: true }];
const lineAttrs = [{ header: 2 }, { list: "ordered" }, { blockquote: true }];
function boundaries(text) { const b = [0]; let i = 0; for (const ch of text) { i += ch.length; b.push(i); } return b; }
function randomDocument(r) {
  const ops = []; const n = 2 + Math.floor(r() * 6);
  for (let i = 0; i < n; i++) {
    if (r() < 0.12) { ops.push({ insert: { image: "data:image/png;base64,AAAA" + i } }); continue; }
    const text = words[Math.floor(r() * words.length)];
    const attributes = text === "\n" && r() < 0.5 ? lineAttrs[Math.floor(r() * lineAttrs.length)] : attrSets[Math.floor(r() * attrSets.length)];
    ops.push(attributes ? { insert: text, attributes } : { insert: text });
  }
  ops.push({ insert: "\n" });
  return ops;
}
function unitsOf(ops) { // boundaries in UTF-16 over the whole document
  let all = [0], offset = 0;
  for (const op of ops) {
    if (typeof op.insert === "string") { for (const b of boundaries(op.insert).slice(1)) all.push(offset + b); offset += op.insert.length; }
    else { offset += 1; all.push(offset); }
  }
  return all;
}
function randomChange(r, docOps) {
  const cuts = unitsOf(docOps); const total = cuts[cuts.length - 1];
  const ops = []; let pos = 0;
  const steps = 1 + Math.floor(r() * 3);
  for (let s = 0; s < steps; s++) {
    const ahead = cuts.filter(c => c > pos && c < total);
    if (!ahead.length) break;
    const to = ahead[Math.floor(r() * ahead.length)];
    ops.push({ retain: to - pos }); pos = to;
    const choice = r();
    if (choice < 0.4) { ops.push({ insert: words[Math.floor(r() * words.length)] }); }
    else if (choice < 0.7) {
      const ends = cuts.filter(c => c > pos && c <= total - 1); if (!ends.length) continue;
      const end = ends[Math.min(ends.length - 1, Math.floor(r() * 3))];
      ops.push({ delete: end - pos }); pos = end;
    } else {
      const ends = cuts.filter(c => c > pos && c <= total); if (!ends.length) continue;
      const end = ends[Math.min(ends.length - 1, Math.floor(r() * 3))];
      const attributes = r() < 0.3 ? { bold: null } : attrSets[1 + Math.floor(r() * (attrSets.length - 1))];
      ops.push({ retain: end - pos, attributes }); pos = end;
    }
  }
  return ops;
}

(async () => {
  const browser = await chromium.launch();
  const page = await browser.newPage();
  await page.setContent("<!doctype html><div id=e></div>");
  await page.addScriptTag({ content: fs.readFileSync(quillPath, "utf8") });
  const r = rng(20261122);
  let cases = handCases.map(c => ({ ...c }));
  if (mode === "write") {
    for (let i = 0; i < 60; i++) {
      const doc = randomDocument(r);
      const a = randomChange(r, doc), b = randomChange(r, doc);
      cases.push({ name: `random ${i} compose`, kind: "compose", a: doc, b: a });
      cases.push({ name: `random ${i} transform`, kind: "transform", base: doc, a, b, priority: r() < 0.5 });
      cases.push({ name: `random ${i} position`, kind: "position", a, index: Math.floor(r() * 12), priority: r() < 0.5 });
    }
  } else {
    cases = JSON.parse(fs.readFileSync(corpusPath, "utf8")).cases;
  }
  const computed = await page.evaluate((cases) => {
    const Delta = window.Quill.import("delta");
    return cases.map(c => {
      const a = new Delta(c.a);
      if (c.kind === "compose") return { expected: a.compose(new Delta(c.b)).ops };
      if (c.kind === "transform") {
        const out = { expected: a.transform(new Delta(c.b), c.priority).ops };
        if (c.base) { // convergence: base∘a∘a'(b) == base∘b∘b'(a)
          const base = new Delta(c.base), b = new Delta(c.b);
          const left = base.compose(a).compose(a.transform(b, true));
          const right = base.compose(b).compose(b.transform(a, false));
          const canon = v => JSON.stringify(v, (k, x) => x && typeof x === "object" && !Array.isArray(x) ? Object.fromEntries(Object.keys(x).sort().map(key => [key, x[key]])) : x);
          out.converged = left.ops; const flat = ops => ops.flatMap(op => typeof op.insert === "string" ? Array.from(op.insert).map(ch => [ch, op.attributes || {}]) : [[op.insert, op.attributes || {}]]);
          out.convergedEqual = canon(flat(left.ops)) === canon(flat(right.ops));
          if (!out.convergedEqual) out.debug = [canon(left.ops), canon(right.ops)];
        }
        return out;
      }
      return { expected: a.transformPosition(c.index, c.priority) };
    });
  }, cases);
  await browser.close();
  let failures = 0;
  cases.forEach((c, i) => {
    const got = computed[i];
    if (mode === "write") {
      c.expected = got.expected; if (got.converged) c.converged = got.converged;
      if (got.convergedEqual === false) { console.error("Quill does not converge:", c.name, got.debug); failures++; }
    } else {
      const same = JSON.stringify(got.expected) === JSON.stringify(c.expected) && (!c.converged || JSON.stringify(got.converged) === JSON.stringify(c.converged));
      if (!same) { console.error("MISMATCH", c.name, JSON.stringify(got.expected), "≠", JSON.stringify(c.expected)); failures++; }
    }
  });
  if (mode === "write") {
    fs.writeFileSync(corpusPath, JSON.stringify({ schema: "haven.richtext.delta.vectors.v1", source: "Quill bundle in CellScaffold Public/vendor/quill/quill.js, Quill.import('delta')", cases }, null, 1) + "\n");
    console.log(`wrote ${cases.length} cases to ${corpusPath}`);
  } else {
    console.log(`${cases.length - failures}/${cases.length} cases agree with Quill`);
  }
  process.exit(failures ? 1 : 0);
})();
