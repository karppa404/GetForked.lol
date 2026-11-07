"use client";

import { useEffect, useRef, useState, type FormEvent } from "react";
import { describeError, isAbort } from "@/lib/dashboard/http";
import { routeHref, useResource } from "@/lib/dashboard/hooks";
import { EmptyState, ErrorNotice, LoadingBlock, Spinner, formatDate, useDashboard } from "./ui";

export function ProjectsView() {
  const { workspace, openPreview } = useDashboard();
  const projects = useResource(`projects:${workspace.kind}`, (signal) => workspace.listProjects(signal));
  const [creating, setCreating] = useState(false);

  useEffect(() => workspace.subscribe?.(projects.reload), [workspace, projects.reload]);
  useEffect(() => {
    document.title = "Projects — Retrace";
  }, []);

  return (
    <div className="rd-page">
      <header className="rd-page-head">
        <div>
          <p className="rd-eyebrow"><span aria-hidden="true" /> WORKSPACE</p>
          <h1>Projects<em>.</em></h1>
          <p className="rd-lede">One project per app you’re trying to understand. Sessions recorded on your Mac land here for review and analysis.</p>
        </div>
        {!creating && (
          <button type="button" className="rd-btn rd-btn--primary" onClick={() => setCreating(true)}>
            New project <span aria-hidden="true">+</span>
          </button>
        )}
      </header>

      {creating && (
        <CreateProject
          onCancel={() => setCreating(false)}
          onCreated={(p) => {
            setCreating(false);
            projects.setData((prev) => [...(prev ?? []), p]);
            window.location.hash = routeHref({ name: "project", projectId: p.id });
          }}
        />
      )}

      {projects.error ? (
        <ErrorNotice error={projects.error} title="Couldn’t load projects" onRetry={projects.reload}>
          {workspace.kind === "backend" && (
            <button type="button" className="rd-btn rd-btn--ghost rd-btn--small" onClick={openPreview}>Open the preview workspace instead</button>
          )}
        </ErrorNotice>
      ) : !projects.data ? (
        <LoadingBlock label="Loading projects" />
      ) : projects.data.length === 0 ? (
        <EmptyState symbol="↶" title="No projects yet" action={!creating && <button type="button" className="rd-btn rd-btn--primary" onClick={() => setCreating(true)}>Create your first project</button>}>
          <p>Create a project for the app you want to understand, then connect the macOS recorder to it with a room code.</p>
        </EmptyState>
      ) : (
        <ul className="rd-rows" aria-label="Projects">
          {projects.data.map((p, i) => (
            <li key={p.id}>
              <a className="rd-row rd-row--project" href={routeHref({ name: "project", projectId: p.id })}>
                <span className="rd-row-index" aria-hidden="true">{String(i + 1).padStart(2, "0")}</span>
                <span className="rd-row-main">
                  <strong>{p.name}</strong>
                  <span className="rd-muted">Created {formatDate(p.created_at)}</span>
                </span>
                <span className="rd-row-meta">{p.session_count === undefined ? "" : `${p.session_count} ${p.session_count === 1 ? "session" : "sessions"}`}</span>
                <span className="rd-row-arrow" aria-hidden="true">→</span>
              </a>
            </li>
          ))}
        </ul>
      )}
    </div>
  );
}

function CreateProject({ onCancel, onCreated }: { onCancel: () => void; onCreated: (p: { id: string; name: string }) => void }) {
  const { workspace } = useDashboard();
  const [name, setName] = useState("");
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const input = useRef<HTMLInputElement>(null);
  const abort = useRef<AbortController | null>(null);

  useEffect(() => {
    input.current?.focus();
    return () => abort.current?.abort();
  }, []);

  async function submit(e: FormEvent) {
    e.preventDefault();
    const trimmed = name.trim();
    if (!trimmed) return setError("Give the project a name.");
    if (trimmed.length > 80) return setError("Keep the name under 80 characters.");
    abort.current = new AbortController();
    setBusy(true);
    setError(null);
    try {
      onCreated(await workspace.createProject(trimmed, abort.current.signal));
    } catch (err) {
      if (!isAbort(err)) {
        setError(describeError(err));
        setBusy(false);
      }
    }
  }

  return (
    <form className="rd-create" onSubmit={submit} aria-label="Create project">
      <label htmlFor="rd-project-name">Project name</label>
      <div className="rd-create-row">
        <input
          id="rd-project-name"
          ref={input}
          value={name}
          onChange={(e) => setName(e.target.value)}
          onKeyDown={(e) => e.key === "Escape" && onCancel()}
          placeholder="e.g. Billing desktop app"
          maxLength={120}
          aria-invalid={Boolean(error)}
          aria-describedby={error ? "rd-project-error" : undefined}
          disabled={busy}
        />
        <button type="submit" className="rd-btn rd-btn--primary" disabled={busy}>{busy ? <><Spinner label="Creating" /> Creating…</> : "Create project"}</button>
        <button type="button" className="rd-btn rd-btn--ghost" onClick={onCancel} disabled={busy}>Cancel</button>
      </div>
      {error && <p id="rd-project-error" className="rd-form-error" role="alert">{error}</p>}
      {workspace.kind === "preview" && <p className="rd-fine">Preview projects are saved only in this browser.</p>}
    </form>
  );
}
