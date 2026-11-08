"use client";

import { useEffect, useId, useMemo, useRef, useState, type KeyboardEvent, type ReactNode } from "react";
import { SAMPLE_FILES, SAMPLE_PATHS, SAMPLE_ROOT } from "./spec-sample.data";
import "./spec-sheet.css";

const FEATURE = "specs/001-ledgerline-inventory-3-1-clone/spec.md";

// Tab order is for people skimming; COPY_ORDER is the read order AGENTS.md gives a coding agent.
export const FILES = [
  { path: FEATURE, label: "Spec", note: "What to build: user stories, acceptance scenarios, requirements and open questions, in GitHub Spec Kit format." },
  { path: "reference/pages.md", label: "Pages", note: "What each captured page shows, and which controls were seen but not exercised." },
  { path: "contracts/arazzo.json", label: "Flows", note: "The API calls each scanned workflow made, in order. Links to UI actions are by timing only." },
  { path: "contracts/openapi.json", label: "API", note: "Endpoints and response shapes seen on the wire. Shapes only: values and headers are not included." },
  { path: "reference/rebuild-profile.json", label: "Rebuild", note: "Target platform, legacy-stack evidence, proposed modern alternatives and performance goals, each with its limits." },
  { path: "AGENTS.md", label: "Agent brief", note: "Where a coding agent starts: what to read first, defaults, and the test loop it is scored on." },
] as const;
const COPY_ORDER = ["AGENTS.md", FEATURE, "contracts/openapi.json", "contracts/arazzo.json", "reference/pages.md", "reference/rebuild-profile.json"];

const OMITTED = (() => {
  const rest = SAMPLE_PATHS.filter((p) => !(p in SAMPLE_FILES));
  const count = (prefix: string) => rest.filter((p) => p.startsWith(prefix)).length;
  return [
    { dir: "reference/screens/", what: `${count("reference/screens/")} screenshots` },
    { dir: "evals/", what: `${count("evals/")} Playwright tests and scenarios` },
    { dir: "evidence/", what: `${count("evidence/")} evidence graphs` },
  ];
})();

const fence = (path: string) => (path.endsWith(".json") ? "json" : "markdown");
export const COPY_TEXT = [
  `# ${SAMPLE_ROOT} (sample)`,
  "",
  "Sample Retrace clone spec bundle for a fictional legacy app, Ledgerline Inventory 3.1. It contains the bundle's text files; " +
    `reference screenshots, Playwright evals and evidence graphs are omitted. Start with AGENTS.md. Scan coverage is partial, ` +
    "stack entries are advertised signals rather than proof, and performance goals are proposals, not measurements.",
  "",
  ...COPY_ORDER.map((p) => `## ${p}\n\n\`\`\`${fence(p)}\n${SAMPLE_FILES[p].trimEnd()}\n\`\`\`\n`),
].join("\n");

/* Minimal highlighter: enough colour to scan the file, no dependency. */
const MD_INLINE = /(`[^`]+`|\*\*[^*]+\*\*|\[NEEDS CLARIFICATION[^\]]*\]|\[[^\]]+\]\([^)]+\))/g;
const JSON_TOKEN = /("(?:[^"\\]|\\.)*")(\s*:)?|(-?\b\d+(?:\.\d+)?\b)|\b(true|false|null)\b/g;

function mdLine(line: string, key: number): ReactNode {
  if (/^#{1,6} /.test(line)) return <span key={key} className="ss-t-h">{line}</span>;
  const parts = line.split(MD_INLINE).map((part, i) => {
    if (i % 2 === 0) return part;
    const cls = part.startsWith("`") ? "ss-t-code" : part.startsWith("**") ? "ss-t-b" : part.startsWith("[NEEDS") ? "ss-t-flag" : "ss-t-link";
    return <span key={i} className={cls}>{part}</span>;
  });
  return <span key={key}>{parts}</span>;
}

function jsonLine(line: string, key: number): ReactNode {
  const out: ReactNode[] = [];
  let last = 0;
  let statusValue = false;
  for (const m of line.matchAll(JSON_TOKEN)) {
    const at = m.index ?? 0;
    if (at > last) out.push(line.slice(last, at));
    const [whole, str, colon, num] = m;
    if (str && colon) {
      out.push(<span key={at} className="ss-t-key">{str}</span>, colon);
      statusValue = str === '"status"';
    } else {
      const cls = str ? (statusValue ? "ss-t-flag" : "ss-t-str") : num ? "ss-t-num" : "ss-t-lit";
      out.push(<span key={at} className={cls}>{whole}</span>);
    }
    last = at + whole.length;
  }
  if (last < line.length) out.push(line.slice(last));
  return <span key={key}>{out}</span>;
}

function Highlighted({ path }: { path: string }) {
  const nodes = useMemo(() => {
    const render = path.endsWith(".json") ? jsonLine : mdLine;
    // One block per line with a hanging indent, so wrapped lines stay aligned under their own indentation.
    return SAMPLE_FILES[path].trimEnd().split("\n").map((line, i) => {
      const hang = `${line.length - line.trimStart().length + 2}ch`;
      return <span key={i} className="ss-line" style={{ paddingLeft: hang, textIndent: `-${hang}` }}>{line ? render(line, i) : " "}</span>;
    });
  }, [path]);
  return <>{nodes}</>;
}

async function writeClipboard(text: string): Promise<boolean> {
  try {
    await navigator.clipboard.writeText(text);
    return true;
  } catch {
    // Older Safari or a denied permission: fall back to a hidden textarea.
    try {
      const area = document.createElement("textarea");
      area.value = text;
      area.setAttribute("readonly", "");
      area.style.cssText = "position:fixed;top:0;left:0;opacity:0";
      document.body.append(area);
      area.select();
      const ok = document.execCommand("copy");
      area.remove();
      return ok;
    } catch {
      return false;
    }
  }
}

function downloadSample() {
  const url = URL.createObjectURL(new Blob([COPY_TEXT], { type: "text/markdown;charset=utf-8" }));
  const a = document.createElement("a");
  a.href = url;
  a.download = `${SAMPLE_ROOT}.sample.md`;
  document.body.append(a);
  a.click();
  a.remove();
  setTimeout(() => URL.revokeObjectURL(url), 0);
}

const NOTES = [
  { title: "A sample, not a scan", body: "Ledgerline Inventory 3.1 is fictional. These files come from running Retrace’s real exporter on made-up scan data." },
  { title: "Coverage is partial", body: "Codex explores what it can reach safely. Hidden, signed-in, destructive and external paths stay unverified, and the spec lists the gaps." },
  { title: "Stack evidence, not proof", body: "Stack entries come from captured headers such as Server and X-Powered-By. Screenshots can’t reveal languages, frameworks or databases." },
  { title: "Goals, not measurements", body: "Performance targets are proposed budgets for the rebuild. Capture timings include recorder delay and aren’t a baseline." },
];

type CopyState = "idle" | "copied" | "failed";

export function SpecSheet() {
  const [selected, setSelected] = useState(0);
  const [copy, setCopy] = useState<CopyState>("idle");
  const tabs = useRef<(HTMLButtonElement | null)[]>([]);
  const id = useId();
  const file = FILES[selected];
  const slash = file.path.lastIndexOf("/") + 1;

  useEffect(() => {
    if (copy === "idle") return;
    const t = setTimeout(() => setCopy("idle"), 2400);
    return () => clearTimeout(t);
  }, [copy]);

  const onKeyDown = (e: KeyboardEvent<HTMLDivElement>) => {
    const last = FILES.length - 1;
    const next = { ArrowDown: selected + 1, ArrowRight: selected + 1, ArrowUp: selected - 1, ArrowLeft: selected - 1, Home: 0, End: last }[e.key];
    if (next === undefined) return;
    e.preventDefault();
    const i = next > last ? 0 : next < 0 ? last : next;
    setSelected(i);
    tabs.current[i]?.focus();
  };

  const onCopy = async () => setCopy((await writeClipboard(COPY_TEXT)) ? "copied" : "failed");

  return (
    <section className="lp-section ss" id="spec" aria-labelledby="spec-title">
      <h2 id="spec-title" className="lp-h2 ss-h2">A spec sheet your AI agent can build from</h2>
      <p className="ss-lede">
        Every scan exports a clone spec bundle: what to build, what each page shows, the API it called and how to rebuild it.
        Hand the folder to a coding agent. <code>AGENTS.md</code> tells it what to read first and which tests it’s scored on.
      </p>

      <div className="ss-panel">
        <div className="ss-bar">
          <p className="ss-root">
            <FolderGlyph />
            <span className="ss-root-name">{SAMPLE_ROOT}/</span>
            <span className="ss-badge">Sample</span>
          </p>
          <div className="ss-actions">
            <button type="button" className="ss-btn ss-btn--ghost" onClick={downloadSample}>
              <DownloadGlyph />Download .md
            </button>
            <button type="button" className="lp-btn lp-btn--light ss-copy" onClick={onCopy} data-state={copy}>
              {copy === "copied" ? <CheckGlyph /> : <CopyGlyph />}
              {copy === "copied" ? "Copied" : copy === "failed" ? "Copy failed" : "Copy for AI"}
            </button>
            <span className="lp-sr" role="status" aria-live="polite">
              {copy === "copied" ? `Copied ${COPY_ORDER.length} sample files to the clipboard.` : copy === "failed" ? "Couldn’t copy. Use Download .md instead." : ""}
            </span>
          </div>
        </div>

        <div className="ss-body">
          <div className="ss-tabs" role="tablist" aria-label="Sample bundle files" aria-orientation="vertical" onKeyDown={onKeyDown}>
            {FILES.map((f, i) => (
              <button
                key={f.path}
                ref={(el) => { tabs.current[i] = el; }}
                type="button"
                role="tab"
                id={`${id}-tab-${i}`}
                aria-selected={i === selected}
                aria-controls={`${id}-panel`}
                tabIndex={i === selected ? 0 : -1}
                className="ss-tab"
                onClick={() => setSelected(i)}
              >
                <span className="ss-tab-label">{f.label}</span>
                <span className="ss-tab-file">{f.path.slice(f.path.lastIndexOf("/") + 1)}</span>
              </button>
            ))}
          </div>

          <div className="ss-view" role="tabpanel" id={`${id}-panel`} aria-labelledby={`${id}-tab-${selected}`}>
            <div className="ss-view-head">
              <code className="ss-path"><span>{file.path.slice(0, slash)}</span>{file.path.slice(slash)}</code>
              <span className="ss-lines">{SAMPLE_FILES[file.path].trimEnd().split("\n").length} lines</span>
            </div>
            <p className="ss-note">{file.note}</p>
            <pre className="ss-code" tabIndex={0} aria-label={`${file.path}, sample contents`}>
              <code><Highlighted path={file.path} /></code>
            </pre>
          </div>
        </div>

        <p className="ss-foot">
          <span>Also in the bundle</span>
          {OMITTED.map((o) => <span key={o.dir}><code>{o.dir}</code> {o.what}</span>)}
        </p>
      </div>

      <ul className="ss-notes">
        {NOTES.map((n) => (
          <li key={n.title}>
            <h3>{n.title}</h3>
            <p>{n.body}</p>
          </li>
        ))}
      </ul>
    </section>
  );
}

const glyph = { "aria-hidden": true, width: 16, height: 16, viewBox: "0 0 16 16", fill: "none", stroke: "currentColor", strokeWidth: 1.5, strokeLinecap: "round", strokeLinejoin: "round" } as const;
function FolderGlyph() {
  return <svg {...glyph}><path d="M2 4.5c0-.6.4-1 1-1h3l1.5 1.5H13c.6 0 1 .4 1 1v6c0 .6-.4 1-1 1H3c-.6 0-1-.4-1-1z" /></svg>;
}
function CopyGlyph() {
  return <svg {...glyph}><rect x="5.5" y="5.5" width="8" height="8" rx="1.5" /><path d="M10.5 5.5V3.75c0-.7-.55-1.25-1.25-1.25h-5.5C3.05 2.5 2.5 3.05 2.5 3.75v5.5c0 .7.55 1.25 1.25 1.25H5.5" /></svg>;
}
function CheckGlyph() {
  return <svg {...glyph} strokeWidth={1.8}><path d="m3.5 8.5 3 3 6-7" /></svg>;
}
function DownloadGlyph() {
  return <svg {...glyph}><path d="M8 2.5v8m0 0 3-3m-3 3-3-3M3 13.5h10" /></svg>;
}
