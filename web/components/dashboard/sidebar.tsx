"use client";

import { useEffect, useRef, useState, type FormEvent } from "react";
import { describeError, isAbort } from "@/lib/dashboard/http";
import { routeHref, useRealtimeStatus, type Resource } from "@/lib/dashboard/hooks";
import type { Project } from "@/lib/dashboard/types";
import { Icon, Spinner, useDashboard } from "./ui";

export function Sidebar({ projects, activeId }: { projects: Resource<Project[]>; activeId?: string }) {
  const [creating, setCreating] = useState(false);
  return (
    <nav className="rd-sidebar" aria-label="Workspace">
      <a className="rd-wordmark" href="/" aria-label="Retrace home">Retrace</a>
      <div className="rd-side-head">
        <h2 id="rd-side-projects">Projects</h2>
        <button type="button" className="rd-icon-btn" aria-label="New project" title="New project" onClick={() => setCreating(true)} disabled={creating}>
          <Icon name="plus" />
        </button>
      </div>
      {creating && (
        <CreateProject
          onDone={(p) => {
            setCreating(false);
            if (!p) return;
            projects.setData((prev) => [...(prev ?? []), p]);
            window.location.hash = routeHref({ name: "project", projectId: p.id });
          }}
        />
      )}
      {projects.error ? (
        <p className="rd-side-note">Couldn’t load projects. <button type="button" className="rd-link-btn" onClick={projects.reload}>Retry</button></p>
      ) : !projects.data ? (
        <p className="rd-side-note"><Spinner label="Loading projects" /></p>
      ) : projects.data.length === 0 ? (
        <p className="rd-side-note">No projects yet. Connecting the recorder creates <b>Local workspace</b>.</p>
      ) : (
        <ul className="rd-side-list" aria-labelledby="rd-side-projects">
          {projects.data.map((p) => (
            <li key={p.id}>
              <a href={routeHref({ name: "project", projectId: p.id })} aria-current={p.id === activeId ? "page" : undefined}>
                <span className="rd-side-name">{p.name}</span>
                {p.session_count !== undefined && <span className="rd-side-count">{p.session_count}</span>}
              </a>
            </li>
          ))}
        </ul>
      )}
      <ConnectionFooter />
    </nav>
  );
}

function ConnectionFooter() {
  const { workspace, env, user } = useDashboard();
  const live = useRealtimeStatus(workspace);
  if (workspace.kind === "preview") return <p className="rd-side-foot"><span className="rd-dot rd-dot--muted" aria-hidden="true" />Sample data</p>;
  const host = env.apiBaseUrl?.replace(/^https?:\/\//, "");
  return (
    <div className="rd-side-foot" title={user?.email ? `Signed in locally as ${user.email}` : undefined}>
      <span className={`rd-dot${live === "live" ? " rd-dot--live" : ""}`} aria-hidden="true" />
      <span>
        <span className="rd-side-foot-main">{live === "live" ? "Live" : live === "connecting" ? "Connecting…" : "Connected"}</span>
        <span className="rd-side-foot-sub rd-mono">{host}</span>
      </span>
    </div>
  );
}

function CreateProject({ onDone }: { onDone: (p: Project | null) => void }) {
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
      onDone(await workspace.createProject(trimmed, abort.current.signal));
    } catch (err) {
      if (!isAbort(err)) {
        setError(describeError(err));
        setBusy(false);
      }
    }
  }

  return (
    <form className="rd-side-create" onSubmit={submit} aria-label="Create project">
      <label htmlFor="rd-project-name" className="rd-visually-hidden">Project name</label>
      <input
        id="rd-project-name"
        ref={input}
        value={name}
        onChange={(e) => setName(e.target.value)}
        onKeyDown={(e) => e.key === "Escape" && onDone(null)}
        placeholder="Project name"
        maxLength={120}
        aria-invalid={Boolean(error)}
        aria-describedby={error ? "rd-project-error" : undefined}
        disabled={busy}
      />
      <div className="rd-side-create-actions">
        <button type="submit" className="rd-btn rd-btn--primary rd-btn--small" disabled={busy}>{busy ? "Creating…" : "Create"}</button>
        <button type="button" className="rd-btn rd-btn--ghost rd-btn--small" onClick={() => onDone(null)} disabled={busy}>Cancel</button>
      </div>
      {error && <p id="rd-project-error" className="rd-form-error" role="alert">{error}</p>}
    </form>
  );
}
