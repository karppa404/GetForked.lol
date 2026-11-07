"use client";

import { useEffect } from "react";
import { formatDuration } from "@/lib/dashboard/graph";
import { routeHref, useResource } from "@/lib/dashboard/hooks";
import { ConnectRecorder } from "./connect-recorder";
import { EmptyState, ErrorNotice, LoadingBlock, NetworkBadge, StatusPill, formatDate, useDashboard } from "./ui";

export function ProjectView({ projectId }: { projectId: string }) {
  const { workspace } = useDashboard();
  const projects = useResource(`projects:${workspace.kind}`, (signal) => workspace.listProjects(signal));
  const sessions = useResource(`sessions:${workspace.kind}:${projectId}`, (signal) => workspace.listSessions(projectId, signal));
  const project = projects.data?.find((p) => p.id === projectId);

  useEffect(() => workspace.subscribe?.(sessions.reload), [workspace, sessions.reload]);
  useEffect(() => {
    if (project) document.title = `${project.name} — Retrace`;
  }, [project]);

  return (
    <div className="rd-page">
      <nav className="rd-crumbs" aria-label="Breadcrumb">
        <a href="#/">Projects</a>
        <span aria-hidden="true">/</span>
        <span aria-current="page">{project?.name ?? "Project"}</span>
      </nav>
      <header className="rd-page-head">
        <div>
          <p className="rd-eyebrow"><span aria-hidden="true" /> PROJECT</p>
          <h1>{project?.name ?? (projects.error ? "Project" : " ")}</h1>
          <p className="rd-lede">Each session is one demonstrated task. Analyze it to map screens, actions and — when captured — the API calls behind them.</p>
        </div>
        <button type="button" className="rd-btn rd-btn--ghost rd-btn--small" onClick={sessions.reload} disabled={sessions.loading}>
          {sessions.loading && sessions.data ? "Refreshing…" : "Refresh"}
        </button>
      </header>

      <div className="rd-project-grid">
        <section aria-labelledby="rd-sessions-title" className="rd-sessions">
          <div className="rd-section-head">
            <h2 id="rd-sessions-title">Sessions</h2>
            {sessions.data && <span className="rd-count">{sessions.data.length}</span>}
          </div>
          {sessions.error ? (
            <ErrorNotice error={sessions.error} title="Couldn’t load sessions" onRetry={sessions.reload} />
          ) : !sessions.data ? (
            <LoadingBlock label="Loading sessions" />
          ) : sessions.data.length === 0 ? (
            <EmptyState symbol="⌘" title="No sessions yet">
              <ol className="rd-steps-list">
                <li>Connect the macOS recorder with a room code.</li>
                <li>Pick the app and demonstrate one task.</li>
                <li>Review the redacted evidence on your Mac, then upload.</li>
              </ol>
            </EmptyState>
          ) : (
            <ul className="rd-rows" aria-label="Sessions">
              {sessions.data.map((s) => (
                <li key={s.id}>
                  <a className="rd-row rd-row--session" href={routeHref({ name: "session", projectId, sessionId: s.id })}>
                    <span className="rd-app-glyph" aria-hidden="true">{s.app.name.slice(0, 1)}</span>
                    <span className="rd-row-main">
                      <strong>{s.task}</strong>
                      <span className="rd-muted">{s.app.name} · {formatDate(s.started_at, true)} · {formatDuration(s.duration_ms)}</span>
                    </span>
                    <span className="rd-row-badges">
                      <StatusPill status={s.status} />
                      <NetworkBadge status={s.network_status} />
                    </span>
                    <span className="rd-row-arrow" aria-hidden="true">→</span>
                  </a>
                </li>
              ))}
            </ul>
          )}
        </section>
        <ConnectRecorder projectId={projectId} />
      </div>
    </div>
  );
}
