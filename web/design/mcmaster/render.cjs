// Captures the real mcmaster.com home page (the "before") and renders the unofficial redesign concept (after.html) at the same size.
// Dev-only, not part of the site build. Read-only browsing of one public page: no login, no form submits.
// From web/:
//   npm i --no-save playwright-core   (once; uses the installed Google Chrome)
//   node design/mcmaster/render.cjs            capture the live site, then render the concept
//   node design/mcmaster/render.cjs --concept  re-render the concept from the cached capture only
const fs = require("node:fs");
const path = require("node:path");
const { chromium } = require("playwright-core");

const W = 1440, H = 900, SCALE = 2;
const MAX_BYTES = 300 * 1024;
const HOME = "https://www.mcmaster.com/";
const UA = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/142.0.0.0 Safari/537.36";
const here = __dirname;
const web = path.resolve(here, "../..");
const out = path.join(web, "public/mcmaster");
const cache = path.join(here, ".cache");

const kb = (f) => `${(fs.statSync(f).size / 1024).toFixed(0)} KB`;

/** Encode a PNG to WebP with the browser's own encoder, stepping quality down to fit MAX_BYTES. */
async function toWebp(page, png, file) {
  for (const q of [0.84, 0.78, 0.72, 0.66, 0.6]) {
    const b64 = await page.evaluate(async ({ b64, q }) => {
      const img = new Image();
      img.src = "data:image/png;base64," + b64;
      await img.decode();
      const c = document.createElement("canvas");
      c.width = img.naturalWidth;
      c.height = img.naturalHeight;
      c.getContext("2d").drawImage(img, 0, 0);
      return c.toDataURL("image/webp", q).split(",")[1];
    }, { b64: png.toString("base64"), q });
    const buf = Buffer.from(b64, "base64");
    if (buf.length <= MAX_BYTES || q === 0.6) {
      fs.writeFileSync(file, buf);
      console.log(`${path.relative(web, file)}  ${kb(file)}  q=${q}`);
      return;
    }
  }
}

/** Screenshot the live home page, and cache its product tiles for the concept to reuse. */
async function capture(browser, encoder) {
  const ctx = await browser.newContext({ viewport: { width: W, height: H }, deviceScaleFactor: SCALE, userAgent: UA, locale: "en-US" });
  const page = await ctx.newPage();
  fs.mkdirSync(path.join(cache, "tiles"), { recursive: true });

  const res = await page.goto(HOME, { waitUntil: "domcontentloaded", timeout: 45000 });
  if (!res || res.status() !== 200) throw new Error(`${HOME} returned ${res && res.status()}; not faking a capture`);
  await page.waitForLoadState("networkidle", { timeout: 20000 }).catch(() => {});
  await page.waitForTimeout(2500);
  await page.evaluate(() => document.fonts.ready);
  const png = await page.screenshot({ type: "png" });
  fs.writeFileSync(path.join(cache, "home.png"), png);
  await toWebp(encoder, png, path.join(out, "home.webp"));

  // Product art for the concept, cut from the live page's own tiles (cached locally, not committed).
  let n = 0;
  for (const t of await page.$$('a[href^="/products/"] > span[class^="s"]')) {
    const href = await t.evaluate((el) => el.parentElement.getAttribute("href"));
    const slug = href.replace(/^\/products\//, "").replace(/\/$/, "");
    const file = path.join(cache, "tiles", `${slug}.png`);
    if (fs.existsSync(file) || !(await t.isVisible())) continue;
    await t.screenshot({ path: file, omitBackground: true }).then(() => n++).catch(() => {});
  }
  console.log(`cached ${n} product tiles`);
  await ctx.close();
}

async function concept(browser, encoder) {
  const page = await browser.newPage({ viewport: { width: W, height: H }, deviceScaleFactor: SCALE });
  await page.goto("file://" + path.join(here, "after.html"));
  await page.evaluate(() => document.fonts.ready);
  await page.waitForFunction(() => [...document.images].every((i) => i.complete));
  const missing = await page.$$eval("img", (is) => is.filter((i) => !i.naturalWidth).map((i) => i.getAttribute("src")));
  if (missing.length) console.warn("missing tiles:", missing.join(", "));
  const png = await page.screenshot({ type: "png" });
  fs.writeFileSync(path.join(cache, "after.png"), png);
  await toWebp(encoder, png, path.join(out, "after.webp"));
  await page.close();
}

(async () => {
  fs.mkdirSync(out, { recursive: true });
  const browser = await chromium.launch({ channel: "chrome", args: ["--disable-blink-features=AutomationControlled"] });
  const encoder = await browser.newPage();
  if (!process.argv.includes("--concept")) await capture(browser, encoder);
  await concept(browser, encoder);
  await browser.close();
})().catch((e) => { console.error(e); process.exit(1); });
