"use client";

import { useEffect } from "react";
import { formatDuration } from "@/lib/dashboard/graph";
import { routeHref, useResource, type Resource } from "@/lib/dashboard/hooks";
import type { Project } from "@/lib/dashboard/types";
import { EmptyState, ErrorNotice, Icon, LoadingBlock, NetworkBadge, StatusPill, formatDate, useDashboard } from "./ui";

function RecorderSteps() {
  return (
    <ol className="rd-steps">
      <li><span>Open the Retrace menu bar app, choose Connection, then <b>Connect to Local workspace</b>.</span></li>
      <li><span>Select the app to observe, then work in it as you normally would.</span></li>
      <li><span>Stop, review the captured evidence, and upload it for analysis.</span></li>
    </ol>
  );
}

export function ProjectView({ projectId, projects }: { projectId?: string; projects: Resource<Project[]> }) {
  const { workspace } = useDashboard();
  const project = projects.data?.find((p) => p.id === projectId);
  const sessions = useResource(`sessions:${workspace.kind}:${projectId ?? ""}`, (signal) => (projectId ? workspace.listSessions(projectId, signal) : Promise.resolve([])));

  useEffect(() => workspace.subscribe?.(sessions.reload), [workspace, sessions.reload]);
  useEffect(() => {
    document.title = project ? `${project.name} · Retrace` : "Retrace";
  }, [project]);

  if (projects.error) return <div className="rd-page"><ErrorNotice error={projects.error} title="Couldn’t load projects" onRetry={projects.reload} /></div>;
  if (!projects.data) return <div className="rd-page"><LoadingBlock label="Loading workspace" /></div>;
  if (!projectId) {
    return (
      <div className="rd-page">
        <EmptyState title="Connect the recorder to get started">
          <p>The recorder creates a shared <b>Local workspace</b> project the first time it connects. Recordings appear here after you upload them.</p>
          <RecorderSteps />
        </EmptyState>
      </div>
    );
  }

  return (
    <div className="rd-page">
      <header className="rd-page-head">
        <div>
          <h1>{project?.name ?? "Project"}</h1>
          <p className="rd-muted">
            {sessions.data ? `${sessions.data.length} ${sessions.data.length === 1 ? "recording" : "recordings"}` : "Recordings"}
            {project?.created_at && <> · created {formatDate(project.created_at)}</>}
          </p>
        </div>
        <button type="button" className="rd-btn rd-btn--ghost rd-btn--small" onClick={sessions.reload} disabled={sessions.loading}>
          <Icon name="refresh" /> {sessions.loading && sessions.data ? "Refreshing…" : "Refresh"}
        </button>
      </header>

      {!project ? (
        <ErrorNotice error={new Error("This project isn’t in your workspace.")} title="Project not found" />
      ) : sessions.error ? (
        <ErrorNotice error={sessions.error} title="Couldn’t load recordings" onRetry={sessions.reload} />
      ) : !sessions.data ? (
        <LoadingBlock label="Loading recordings" />
      ) : sessions.data.length === 0 ? (
        <EmptyState title="No recordings yet">
          <RecorderSteps />
          <p className="rd-fine">Nothing leaves your Mac until you review a recording and choose to upload it.</p>
        </EmptyState>
      ) : (
        <div className="rd-table" role="table" aria-label="Recordings">
          <div className="rd-table-head" role="row">
            <span role="columnheader">App</span>
            <span role="columnheader">Recorded</span>
            <span role="columnheader">Length</span>
            <span role="columnheader">Analysis</span>
            <span role="columnheader">Network</span>
          </div>
          {sessions.data.map((s) => (
            <a key={s.id} role="row" className="rd-table-row" href={routeHref({ name: "session", projectId, sessionId: s.id })} aria-label={`${s.app.name}, recorded ${formatDate(s.started_at, true)}`}>
              <span role="cell" className="rd-table-app"><strong>{s.app.name}</strong>{s.app.bundle_id && <span className="rd-mono rd-muted">{s.app.bundle_id}</span>}</span>
              <span role="cell">{formatDate(s.started_at, true)}</span>
              <span role="cell" className="rd-tabular">{formatDuration(s.duration_ms)}</span>
              <span role="cell"><StatusPill status={s.status} /></span>
              <span role="cell"><NetworkBadge status={s.network_status} /></span>
            </a>
          ))}
        </div>
      )}
    </div>
  );
}
