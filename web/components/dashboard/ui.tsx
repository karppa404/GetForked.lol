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
  signOut: () => void;
  /** Explicit, user-initiated switch to the preview workspace. */
  openPreview: () => void;
  leavePreview: () => void;
}

export const DashboardContext = createContext<DashboardContextValue | null>(null);

export function useDashboard(): DashboardContextValue {
  const v = useContext(DashboardContext);
  if (!v) throw new Error("useDashboard outside provider");
  return v;
}

export function Brand({ compact = false }: { compact?: boolean }) {
  return (
    <a className={`rd-brand${compact ? " rd-brand--compact" : ""}`} href="/" aria-label="Retrace home">
      <span className="rd-brand-mark" aria-hidden="true">↶</span>retrace<span className="rd-brand-period">.</span>
    </a>
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
      <span className="rd-notice-icon" aria-hidden="true">!</span>
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

export function EmptyState({ symbol, title, children, action }: { symbol: string; title: string; children?: ReactNode; action?: ReactNode }) {
  return (
    <div className="rd-empty">
      <span className="rd-empty-symbol" aria-hidden="true">{symbol}</span>
      <h3>{title}</h3>
      {children && <div className="rd-empty-body">{children}</div>}
      {action && <div className="rd-empty-action">{action}</div>}
    </div>
  );
}

const STATUS_COPY: Record<string, { label: string; tone: string }> = {
  uploaded: { label: "Ready to analyze", tone: "neutral" },
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
  none_observed: { label: "No requests observed", title: "Network capture was on, but no requests happened during this task." },
  not_captured: { label: "Network not captured", title: "This session was recorded without network capture." },
};

export function NetworkBadge({ status }: { status?: NetworkStatus }) {
  if (!status) return null;
  const c = NETWORK_COPY[status];
  return (
    <span className={`rd-net rd-net--${status}`} title={c.title}>
      <span aria-hidden="true">{status === "observed" ? "⇄" : status === "none_observed" ? "∅" : "⊘"}</span>
      {c.label}
    </span>
  );
}

const dateFmt = new Intl.DateTimeFormat("en-US", { month: "short", day: "numeric", year: "numeric" });
const dateTimeFmt = new Intl.DateTimeFormat("en-US", { month: "short", day: "numeric", hour: "numeric", minute: "2-digit" });

export function formatDate(iso?: string, withTime = false): string {
  if (!iso) return "—";
  const d = new Date(iso);
  if (Number.isNaN(d.getTime())) return "—";
  return (withTime ? dateTimeFmt : dateFmt).format(d);
}
