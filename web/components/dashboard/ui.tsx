"use client";

import { createContext, useContext, type ReactNode } from "react";
import type { DashboardEnvironment } from "@/lib/dashboard/config";
import { describeError } from "@/lib/dashboard/http";
import type { NetworkStatus, SessionStatus, User } from "@/lib/dashboard/types";
import type { Workspace } from "@/lib/dashboard/workspace";

export interface DashboardContextValue {
  workspace: Workspace;
  env: DashboardEnvironment;
  user: User | null;
  /** Sign in to the local API again (also leaves the sample data). */
  reconnect: () => void;
}

export const DashboardContext = createContext<DashboardContextValue | null>(null);

export function useDashboard(): DashboardContextValue {
  const v = useContext(DashboardContext);
  if (!v) throw new Error("useDashboard outside provider");
  return v;
}

const ICONS = {
  close: "M4 4l8 8M12 4l-8 8",
  plus: "M8 3v10M3 8h10",
  download: "M8 2.5v8m0 0L4.75 7.25M8 10.5l3.25-3.25M3 13.5h10",
  external: "M6.5 3.5h-3v9h9v-3M9 3h4v4M13 3L7.5 8.5",
  refresh: "M13 8a5 5 0 1 1-1.46-3.54M13 3v2.5h-2.5",
  back: "M10 3.5L5.5 8l4.5 4.5",
} as const;

export function Icon({ name }: { name: keyof typeof ICONS }) {
  return (
    <svg className="rd-icon" width="16" height="16" viewBox="0 0 16 16" aria-hidden="true" focusable="false">
      <path d={ICONS[name]} fill="none" stroke="currentColor" strokeWidth="1.5" strokeLinecap="round" strokeLinejoin="round" />
    </svg>
  );
}

export function Spinner({ label = "Loading" }: { label?: string }) {
  return (
    <span className="rd-spinner" role="status">
      <span aria-hidden="true" />
      <span className="rd-visually-hidden">{label}</span>
    </span>
  );
}

export function LoadingBlock({ label }: { label: string }) {
  return (
    <div className="rd-loading-block">
      <Spinner label={label} />
      <span>{label}…</span>
    </div>
  );
}

export function ErrorNotice({ error, title = "Something went wrong", onRetry, children }: { error: unknown; title?: string; onRetry?: () => void; children?: ReactNode }) {
  return (
    <div className="rd-notice rd-notice--error" role="alert">
      <div>
        <strong>{title}</strong>
        <p>{describeError(error)}</p>
        {(onRetry || children) && (
          <div className="rd-notice-actions">
            {onRetry && <button type="button" className="rd-btn rd-btn--small" onClick={onRetry}>Try again</button>}
            {children}
          </div>
        )}
      </div>
    </div>
  );
}

export function EmptyState({ title, children, action }: { title: string; children?: ReactNode; action?: ReactNode }) {
  return (
    <div className="rd-empty">
      <h3>{title}</h3>
      {children && <div className="rd-empty-body">{children}</div>}
      {action && <div className="rd-empty-action">{action}</div>}
    </div>
  );
}

/** Honest "backend is stopped" screen; never falls back to sample data on its own. */
export function ConnectionError({ env, error, onRetry, onPreview }: { env: DashboardEnvironment; error: unknown; onRetry: () => void; onPreview: () => void }) {
  if (env.problem) {
    return (
      <section className="rd-connect-error" aria-labelledby="rd-conn-title">
        <h1 id="rd-conn-title">Retrace runs on this Mac only</h1>
        <p>
          {env.problem === "page_not_local"
            ? "Open the workspace from http://127.0.0.1:3000 or http://localhost:3000 on the Mac running the Retrace API."
            : "NEXT_PUBLIC_API_BASE_URL must point to a loopback address such as http://127.0.0.1:8000. Remote APIs are not supported."}
        </p>
        <div className="rd-connect-actions">
          <button type="button" className="rd-btn rd-btn--ghost" onClick={onPreview}>View sample data</button>
        </div>
      </section>
    );
  }
  return (
    <section className="rd-connect-error" aria-labelledby="rd-conn-title">
      <h1 id="rd-conn-title">Can’t connect to the local Retrace API</h1>
      <p>{describeError(error)}</p>
      <p className="rd-muted">Start the API on this Mac, then try again:</p>
      <pre className="rd-code">cd backend{"\n"}RETRACE_DEV_AUTH=1 uv run python -m retrace</pre>
      <p className="rd-fine">Expected at <code>{env.apiBaseUrl}</code>. See <code>web/README.md</code> for the full local setup.</p>
      <div className="rd-connect-actions">
        <button type="button" className="rd-btn rd-btn--primary" onClick={onRetry}>Try again</button>
        <button type="button" className="rd-btn rd-btn--ghost" onClick={onPreview}>View sample data</button>
      </div>
    </section>
  );
}

const STATUS_COPY: Record<string, { label: string; tone: string }> = {
  uploaded: { label: "Not analyzed", tone: "neutral" },
  queued: { label: "Queued", tone: "progress" },
  analyzing: { label: "Analyzing", tone: "progress" },
  running: { label: "Analyzing", tone: "progress" },
  analyzed: { label: "Analyzed", tone: "good" },
  succeeded: { label: "Analyzed", tone: "good" },
  failed: { label: "Analysis failed", tone: "bad" },
};

export function StatusPill({ status }: { status: SessionStatus }) {
  const c = STATUS_COPY[status] ?? { label: status, tone: "neutral" };
  return (
    <span className={`rd-pill rd-pill--${c.tone}`}>
      <span aria-hidden="true" className="rd-pill-dot" />
      {c.label}
    </span>
  );
}

const NETWORK_COPY: Record<NetworkStatus, { label: string; title: string }> = {
  observed: { label: "Network observed", title: "Network capture was on and requests were recorded." },
  none_observed: { label: "No requests observed", title: "Network capture was on, but no requests happened during this recording." },
  not_captured: { label: "Network not captured", title: "This recording was made without network capture." },
};

export function NetworkBadge({ status }: { status?: NetworkStatus }) {
  if (!status) return null;
  const c = NETWORK_COPY[status];
  return <span className={`rd-net rd-net--${status}`} title={c.title}>{c.label}</span>;
}

const dateFmt = new Intl.DateTimeFormat("en-US", { month: "short", day: "numeric", year: "numeric" });
const dateTimeFmt = new Intl.DateTimeFormat("en-US", { month: "short", day: "numeric", hour: "numeric", minute: "2-digit" });

export function formatDate(iso?: string, withTime = false): string {
  if (!iso) return "—";
  const d = new Date(iso);
  if (Number.isNaN(d.getTime())) return "—";
  return (withTime ? dateTimeFmt : dateFmt).format(d);
}

/** Recordings have no user-written title: identify them by app and start time. */
export function recordingTitle(s: { app: { name: string }; started_at: string }): string {
  return `${s.app.name} · ${formatDate(s.started_at, true)}`;
}
