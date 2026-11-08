import type { CSSProperties } from "react";
import { BrandMark } from "@/components/brand-mark";
import "./how-it-works.css";

// One scan of mcmaster.com, start to finish. Server-rendered; motion is CSS only and stops under prefers-reduced-motion.
// The screenshot is a real capture (design/mcmaster/render.cjs). Everything drawn over it is our mock of Retrace's UI,
// so endpoint paths, counts and stack rows stay generic rather than describing McMaster-Carr's actual internals.
const BEFORE = { src: "/mcmaster/home.webp", width: 1440, height: 900 } as const;
const AFTER = { src: "/mcmaster/after.webp", width: 1440, height: 900 } as const;
const BEFORE_ALT =
  "The McMaster-Carr home page as it is today: the green McMaster-Carr logo above a search bar, a Choose a Category list down the left, and a Fastening & Joining grid of small grey product photos from Screws & Bolts to Magnets.";
const AFTER_ALT =
  "The same page redesigned: McMaster-Carr in plain green text, a large search field at the top, the same categories in a clean sidebar, and Fastening & Joining shown as tabs over a grid of rounded product cards from Screws & Bolts to Magnets.";

const CALLS = ["/catalog/…", "/search/…", "/product/…"] as const;

// Crops of the captured page (background-position into a 300% wide image) standing in for the scan's frames.
const FRAMES = [
  { t: "00:04", x: 0, y: 0 },
  { t: "00:19", x: 46, y: 18 },
  { t: "00:31", x: 0, y: 62 },
  { t: "00:48", x: 72, y: 44 },
  { t: "01:06", x: 26, y: 70 },
  { t: "01:22", x: 58, y: 96 },
] as const;
const FRAME_COUNT = 38;

const BREAKDOWN = [
  { title: "Pages", count: "3 pages", rows: [["Home", "category index"], ["Category", "Fastening & Joining"], ["Search", "results grid"]] },
  { title: "Endpoints", count: "3 endpoints", kind: "mono", rows: CALLS.map((p) => ["GET", p]) },
  { title: "Stack evidence", count: "2 signals", rows: [["Response headers", "advertised, not verified"], ["Page markup", "rendering hints"]] },
  { title: "Alternatives", count: "2 proposed", rows: [["Next.js + React", "server-rendered catalog"], ["SvelteKit", "lighter client bundle"]] },
  { title: "Performance goals", count: "3 proposed", kind: "inline", rows: [["LCP", "≤ 2.5 s"], ["INP", "≤ 200 ms"], ["Search", "≤ 300 ms p95"]] },
] as const;

function Step({ n, label, title, children }: { n: string; label: string; title: string; children: string }) {
  return (
    <header className="hw-step-head">
      <p className="hw-step-label"><span>{n}</span>{label}</p>
      <h3>{title}</h3>
      <p className="hw-step-copy">{children}</p>
    </header>
  );
}

function Check() {
  return <svg aria-hidden="true" width="12" height="12" viewBox="0 0 12 12" fill="none" stroke="currentColor" strokeWidth="1.8" strokeLinecap="round" strokeLinejoin="round"><path d="m2.5 6.2 2.3 2.3 4.7-5" /></svg>;
}

export function HowItWorks() {
  return (
    <section className="lp-section hw" id="how" aria-labelledby="how-title">
      <h2 id="how-title" className="lp-h2">From one scan to a rebuild plan</h2>
      <p className="lp-sub">One run on mcmaster.com, start to finish.</p>

      <ol className="hw-steps">
        <li className="hw-step">
          <Step n="01" label="Scan" title="Enter a URL, then step away">
            Codex computer use explores the safe, reachable screens. Retrace records every frame and API call.
          </Step>
          <figure className="hw-scan">
            <div className="hw-scan-frame">
              {/* eslint-disable-next-line @next/next/no-img-element -- static local screenshot, no optimizer needed */}
              <img src={BEFORE.src} width={BEFORE.width} height={BEFORE.height} alt={BEFORE_ALT} loading="lazy" decoding="async" />
              <div className="lp-scan-beam" aria-hidden="true" />
              <div className="hw-glow" aria-hidden="true" />
              <div className="hw-pill" aria-hidden="true">
                <i />
                <span>
                  <strong>Retrace is using your desktop — please step away</strong>
                  <small>Scanning mcmaster.com · <b className="hw-count" /> steps · exploring</small>
                </span>
              </div>
              <ul className="hw-ticks" aria-hidden="true">
                <li className="hw-ticks-head">API calls</li>
                {CALLS.map((p) => <li key={p}><Check /><span>GET</span><code>{p}</code></li>)}
              </ul>
            </div>
            <figcaption className="lp-sr">While Codex drives the browser, a red glow edges the screen, a pill asks you to step away and counts steps, and each new API call is ticked off as it is recorded.</figcaption>
          </figure>
        </li>

        <li className="hw-step">
          <Step n="02" label="Confirm" title="Check the frames, then upload">
            Analysis starts only after you tick one box and press Upload &amp; Analyze.
          </Step>
          <div className="hw-confirm">
            <div className="hw-evidence">
              <p className="hw-kicker">Frames <span>{FRAME_COUNT}</span></p>
              <ul className="hw-frames" aria-label={`${FRAME_COUNT} captured frames, six shown`}>
                {FRAMES.map((f) => (
                  <li key={f.t}>
                    <span className="hw-frame" role="img" aria-label={`Frame at ${f.t}`} style={{ "--x": `${f.x}%`, "--y": `${f.y}%` } as CSSProperties} />
                    <time>{f.t}</time>
                  </li>
                ))}
              </ul>
              <p className="hw-kicker">Recorded calls <span>{CALLS.length} endpoints</span></p>
              <ul className="hw-calls">
                {CALLS.map((p, i) => <li key={p}><span>GET</span><code>{p}</code><em>{[14, 9, 6][i]}×</em></li>)}
              </ul>
            </div>

            <div className="hw-panel-wrap">
            <p className="hw-menubar" aria-hidden="true"><BrandMark /><span>9:41</span></p>
            <div className="hw-panel" aria-label="Retrace menu bar panel">
              <p className="hw-panel-app"><span className="hw-panel-icon" aria-hidden="true"><svg width="14" height="14" viewBox="0 0 16 16" fill="none" stroke="currentColor" strokeWidth="1.4"><circle cx="8" cy="8" r="6.2" /><path d="M1.8 8h12.4M8 1.8c1.8 1.9 2.6 3.9 2.6 6.2S9.8 12.3 8 14.2C6.2 12.3 5.4 10.3 5.4 8S6.2 3.7 8 1.8Z" /></svg></span>mcmaster.com<small>Chrome</small></p>
              <div className="hw-panel-card">
                <p className="hw-panel-title">Newest scan is only on this Mac</p>
                <p className="hw-panel-note">Its frames show everything that was visible. Retrace doesn’t detect or remove sensitive content.</p>
                <p className="hw-panel-check"><span className="hw-box" aria-hidden="true"><Check /></span>I reviewed this scan’s {FRAME_COUNT} frames and I’m allowed to share them.</p>
                <span className="hw-upload">
                  <svg aria-hidden="true" width="16" height="16" viewBox="0 0 16 16" fill="none" stroke="currentColor" strokeWidth="1.5" strokeLinecap="round" strokeLinejoin="round"><path d="M4.5 12.5h-.3a3 3 0 0 1-.4-6 4.3 4.3 0 0 1 8.4.4 2.8 2.8 0 0 1-.5 5.6h-.2M8 13.5v-5m-2 2 2-2 2 2" /></svg>
                  Upload &amp; Analyze
                </span>
              </div>
            </div>
            </div>
          </div>
        </li>

        <li className="hw-step">
          <Step n="03" label="Breakdown" title="Get the breakdown">
            Codex maps the pages, flows and API graph, weighs the stack evidence, and proposes a modern stack with goals to hit.
          </Step>
          <div className="hw-report">
            <p className="hw-report-head"><span>Breakdown · mcmaster.com</span><span>Target platform · Web</span></p>
            <dl className="hw-report-grid">
              {BREAKDOWN.map((b) => (
                <div key={b.title}>
                  <dt><span>{b.count}</span>{b.title}</dt>
                  {b.rows.map(([a, z]) => (
                    <dd key={a + z} className={"kind" in b ? `is-${b.kind}` : undefined}><b>{a}</b> {"kind" in b && b.kind === "mono" ? <code>{z}</code> : <span>{z}</span>}</dd>
                  ))}
                </div>
              ))}
            </dl>
          </div>

          <figure className="hw-after">
            <figcaption>
              <span>Hand the spec to a coding agent and rebuild it.</span>
              <a href="#spec">See the spec sheet <span aria-hidden="true">↓</span></a>
            </figcaption>
            {/* eslint-disable-next-line @next/next/no-img-element -- static local screenshot, no optimizer needed */}
            <img src={AFTER.src} width={AFTER.width} height={AFTER.height} alt={AFTER_ALT} loading="lazy" decoding="async" />
          </figure>
        </li>
      </ol>
    </section>
  );
}
