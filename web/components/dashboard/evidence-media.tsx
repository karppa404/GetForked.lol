"use client";

import { useEffect, useState } from "react";
import { describeError } from "@/lib/dashboard/http";
import type { EvidenceItem, Frame, Interaction, NetworkEvent } from "@/lib/dashboard/types";
import { useDashboard } from "./ui";

export function describeInteraction(i: Interaction): { title: string; detail: string } {
  const a = i.accessibility ?? undefined;
  const target = (a?.title || a?.label || "") as string;
  const role = typeof a?.role === "string" ? a.role.replace(/^AX/, "") : "";
  switch (i.kind) {
    case "click":
      return { title: `Click${target ? ` · ${target}` : ""}`, detail: [role, i.x !== undefined ? `at ${Math.round(i.x)}, ${Math.round(i.y ?? 0)}` : ""].filter(Boolean).join(" · ") };
    case "key":
      return { title: `Key · ${i.key ?? "redacted"}`, detail: role || "Typed text is never captured" };
    case "scroll":
      return { title: "Scroll", detail: [i.scroll_dx ? `dx ${i.scroll_dx}` : "", i.scroll_dy ? `dy ${i.scroll_dy}` : ""].filter(Boolean).join(" · ") };
    default:
      return { title: i.kind.charAt(0).toUpperCase() + i.kind.slice(1), detail: target };
  }
}

export function networkPath(e: NetworkEvent): { host: string; path: string } {
  try {
    const u = new URL(e.url);
    return { host: u.host, path: `${u.pathname}${u.search}` };
  } catch {
    return { host: "", path: e.url };
  }
}

export function describeEvidence(item: EvidenceItem): { symbol: string; title: string; detail: string } {
  if (item.kind === "frame") return { symbol: "▢", title: item.data.preview?.title ?? "Screenshot", detail: `${item.data.filename} · ${item.data.width}×${item.data.height}` };
  if (item.kind === "interaction") {
    const d = describeInteraction(item.data);
    return { symbol: item.data.kind === "key" ? "⌨" : item.data.kind === "scroll" ? "↕" : "↖", ...d };
  }
  const { host, path } = networkPath(item.data);
  return { symbol: "⇄", title: `${item.data.method} ${path}`, detail: [item.data.status ? String(item.data.status) : "no status", host].filter(Boolean).join(" · ") };
}

const W = 288;
const H = 180;

/** Sample illustration for preview frames. Clearly labeled; never shown for real sessions. */
export function MockScreenshot({ frame }: { frame: Frame }) {
  const p = frame.preview!;
  const rows = [0, 1, 2, 3, 4];
  return (
    <svg className="rd-mock" viewBox={`0 0 ${W} ${H}`} role="img" aria-label={`Sample illustration of the “${p.title}” screen`}>
      <rect width={W} height={H} rx="6" fill="#fdfdfb" stroke="#dcddd3" />
      <rect width={W} height="16" rx="6" fill="#f1f1ec" />
      <rect y="10" width={W} height="6" fill="#f1f1ec" />
      {[10, 18, 26].map((x) => <circle key={x} cx={x} cy="8" r="2.4" fill="#d4d5cb" />)}
      <rect y="16" width="58" height={H - 16} fill="#f4f4ef" />
      {[0, 1, 2, 3].map((i) => <rect key={i} x="9" y={30 + i * 14} width={i === 0 ? 36 : 30} height="5" rx="2" fill={i === 0 ? "#c9cbbd" : "#e0e1d7"} />)}
      <text x="72" y="36" fontFamily="Manrope, sans-serif" fontWeight="700" fontSize="11" fill="#30342c">{p.title.length > 28 ? `${p.title.slice(0, 27)}…` : p.title}</text>
      {p.variant === "list" && rows.map((i) => (
        <g key={i}>
          <rect x="72" y={50 + i * 22} width="200" height="16" rx="3" fill={i === 1 ? "#fff1e9" : "#f6f6f1"} stroke={i === 1 ? "#efc1a9" : "#ebece4"} />
          <rect x="80" y={56 + i * 22} width={60 + ((i * 29) % 50)} height="4" rx="2" fill="#cfd1c4" />
          <rect x="230" y={56 + i * 22} width="32" height="4" rx="2" fill="#e0e1d7" />
        </g>
      ))}
      {(p.variant === "editor" || p.variant === "settings") && (
        <g>
          {[0, 1, 2].map((i) => (
            <g key={i}>
              <rect x="72" y={50 + i * 30} width="40" height="4" rx="2" fill="#c9cbbd" />
              <rect x="72" y={58 + i * 30} width="200" height="14" rx="3" fill="#fff" stroke="#dfe0d6" />
            </g>
          ))}
          <rect x="214" y="146" width="58" height="16" rx="3" fill="#eb603b" />
          <rect x="226" y="152" width="34" height="4" rx="2" fill="#fff" opacity=".85" />
        </g>
      )}
      {p.variant === "dialog" && (
        <g>
          {rows.slice(0, 4).map((i) => <rect key={i} x="72" y={50 + i * 22} width="200" height="16" rx="3" fill="#f6f6f1" />)}
          <rect x="58" y="16" width={W - 58} height={H - 16} fill="#2c3127" opacity=".18" />
          <rect x="102" y="58" width="140" height="84" rx="6" fill="#fff" stroke="#d8d9cf" />
          <rect x="114" y="72" width="70" height="5" rx="2" fill="#a9ac9c" />
          <rect x="114" y="84" width="112" height="4" rx="2" fill="#e0e1d7" />
          <rect x="114" y="92" width="90" height="4" rx="2" fill="#e0e1d7" />
          <rect x="174" y="118" width="56" height="14" rx="3" fill="#eb603b" />
          <rect x="128" y="118" width="40" height="14" rx="3" fill="#f1f1ec" stroke="#dcddd3" />
        </g>
      )}
      {p.variant === "confirmation" && (
        <g>
          <circle cx="172" cy="92" r="20" fill="#eef1e6" stroke="#9aa98b" />
          <path d="M163 92 l6 6 l12 -13" fill="none" stroke="#6e8159" strokeWidth="3" strokeLinecap="round" strokeLinejoin="round" />
          <rect x="132" y="124" width="80" height="5" rx="2" fill="#c9cbbd" />
          <rect x="146" y="134" width="52" height="4" rx="2" fill="#e0e1d7" />
        </g>
      )}
      <g>
        <rect x={W - 62} y="22" width="54" height="13" rx="3" fill="#fff" stroke="#e1c3b2" />
        <text x={W - 35} y="31" textAnchor="middle" fontSize="6.5" letterSpacing=".8" fill="#b4583a" fontFamily="DM Sans, sans-serif">SAMPLE</text>
      </g>
    </svg>
  );
}

export function FrameImage({ sessionId, frame }: { sessionId: string; frame: Frame }) {
  const { workspace } = useDashboard();
  const [state, setState] = useState<{ url?: string; error?: string; loading: boolean }>({ loading: Boolean(frame.image_url) });

  useEffect(() => {
    if (frame.preview || !frame.image_url || !workspace.frameImage) return;
    const controller = new AbortController();
    let objectUrl: string | null = null;
    setState({ loading: true });
    workspace.frameImage(sessionId, frame.image_url, controller.signal).then(
      (url) => {
        if (url?.startsWith("blob:")) objectUrl = url;
        if (!controller.signal.aborted) setState({ url: url ?? undefined, loading: false });
      },
      (e) => !controller.signal.aborted && setState({ loading: false, error: describeError(e) }),
    );
    return () => {
      controller.abort();
      if (objectUrl) URL.revokeObjectURL(objectUrl);
    };
  }, [frame.id, frame.image_url, frame.preview, sessionId, workspace]);

  if (frame.preview) return <MockScreenshot frame={frame} />;
  if (state.url) {
    // eslint-disable-next-line @next/next/no-img-element
    return <img className="rd-frame-img" src={state.url} alt={`Screenshot ${frame.filename} at ${Math.round(frame.timestamp_ms / 1000)}s`} width={frame.width} height={frame.height} />;
  }
  return (
    <div className="rd-frame-placeholder" style={{ aspectRatio: frame.width && frame.height ? `${frame.width} / ${frame.height}` : "16 / 10" }}>
      <span aria-hidden="true">▢</span>
      <strong>{frame.filename}</strong>
      <span>
        {state.loading ? "Loading screenshot…" : state.error ? `Couldn’t load screenshot: ${state.error}` : "The API didn’t provide an image URL for this frame."}
      </span>
    </div>
  );
}
