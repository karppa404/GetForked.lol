"use client";

import { useCallback, useEffect, useMemo, useRef, useState } from "react";
import { previewChosen, rememberPreviewChoice } from "@/lib/dashboard/auth";
import { createBackendWorkspace, signInForDevelopment } from "@/lib/dashboard/backend";
import { resolveEnvironment, type DashboardEnvironment } from "@/lib/dashboard/config";
import { createApiClient, isAbort } from "@/lib/dashboard/http";
import { createPreviewStore, createPreviewWorkspace } from "@/lib/dashboard/preview";
import { useRealtimeStatus, useResource, useRoute } from "@/lib/dashboard/hooks";
import type { AuthSession, Project } from "@/lib/dashboard/types";
import type { Workspace } from "@/lib/dashboard/workspace";
import { ProjectView } from "./project-view";
import { SessionView } from "./session-view";
import { Sidebar } from "./sidebar";
import { ConnectionError, DashboardContext, LoadingBlock, useDashboard, type DashboardContextValue } from "./ui";

type Mode =
  | { kind: "starting" }
  | { kind: "connecting" }
  | { kind: "error"; error: unknown }
  | { kind: "preview" }
  | { kind: "backend"; auth: AuthSession };

let previewWorkspace: Workspace | null = null;
function getPreviewWorkspace(): Workspace {
  if (!previewWorkspace) {
    let storage: Storage | null = null;
    try {
      storage = window.localStorage;
    } catch {}
    previewWorkspace = createPreviewWorkspace(createPreviewStore(storage, window));
  }
  return previewWorkspace;
}

export function DashboardApp() {
  const [env, setEnv] = useState<DashboardEnvironment | null>(null);
  const [mode, setMode] = useState<Mode>({ kind: "starting" });
  const token = useRef<string | null>(null);

  // Environment depends on window.location, so decide after mount (the page is client-only).
  useEffect(() => {
    const e = resolveEnvironment(window.location.hostname);
    setEnv(e);
    setMode(previewChosen() ? { kind: "preview" } : e.apiBaseUrl ? { kind: "connecting" } : { kind: "error", error: null });
  }, []);

  // Local workspace: sign in automatically through the loopback-only development login.
  useEffect(() => {
    if (mode.kind !== "connecting" || !env?.apiBaseUrl) return;
    const controller = new AbortController();
    signInForDevelopment(createApiClient({ baseUrl: env.apiBaseUrl }), controller.signal).then(
      (auth) => {
        token.current = auth.access_token;
        setMode({ kind: "backend", auth });
      },
      (error) => !isAbort(error) && setMode({ kind: "error", error }),
    );
    return () => controller.abort();
  }, [mode.kind, env?.apiBaseUrl]);

  const backend = useMemo(() => {
    if (!env?.apiBaseUrl || mode.kind !== "backend") return null;
    const client = createApiClient({
      baseUrl: env.apiBaseUrl,
      getToken: () => token.current,
      onUnauthorized: () => {
        token.current = null;
        setMode({ kind: "error", error: new Error("The local API ended this session (it may have restarted).") });
      },
    });
    return { client, workspace: createBackendWorkspace(client) };
  }, [env?.apiBaseUrl, mode.kind]);

  useEffect(() => () => { void backend?.workspace.dispose?.(); }, [backend]);

  const reconnect = useCallback(() => {
    rememberPreviewChoice(false);
    setMode((m) => (env?.apiBaseUrl ? { kind: "connecting" } : m));
  }, [env?.apiBaseUrl]);

  const openPreview = useCallback(() => {
    rememberPreviewChoice(true);
    window.location.hash = "#/";
    setMode({ kind: "preview" });
  }, []);

  const ctx = useMemo<DashboardContextValue | null>(() => {
    if (!env) return null;
    if (mode.kind === "preview") return { workspace: getPreviewWorkspace(), env, user: null, reconnect };
    if (mode.kind === "backend" && backend) return { workspace: backend.workspace, env, user: mode.auth.user, reconnect };
    return null;
  }, [env, mode, backend, reconnect]);

  if (!env || mode.kind === "starting" || mode.kind === "connecting") {
    return (
      <div className="rd-app rd-app--center">
        <LoadingBlock label="Connecting to the local Retrace API" />
      </div>
    );
  }

  if (mode.kind === "error") {
    return (
      <div className="rd-app rd-app--center">
        <ConnectionError env={env} error={mode.error} onRetry={reconnect} onPreview={openPreview} />
      </div>
    );
  }

  if (!ctx) return null;
  return (
    <DashboardContext.Provider value={ctx}>
      <Shell />
    </DashboardContext.Provider>
  );
}

/** Prefer the shared "Local workspace" the recorder connects to; fall back to the first project. */
export function defaultProject(projects: Project[]): Project | undefined {
  return projects.find((p) => p.name.trim().toLowerCase() === "local workspace") ?? projects[0];
}

function Shell() {
  const route = useRoute();
  const { workspace } = useDashboard();
  const projects = useResource(`projects:${workspace.kind}`, (signal) => workspace.listProjects(signal));
  useEffect(() => workspace.subscribe?.(projects.reload), [workspace, projects.reload]);

  const fallback = projects.data ? defaultProject(projects.data) : undefined;
  const activeId = route.name === "projects" ? fallback?.id : route.projectId;

  return (
    <div className="rd-app rd-shell">
      <a className="rd-skip" href="#rd-main" onClick={(e) => { e.preventDefault(); document.getElementById("rd-main")?.focus(); }}>Skip to content</a>
      <Sidebar projects={projects} activeId={activeId} />
      <main id="rd-main" tabIndex={-1} className="rd-main">
        <PreviewBanner />
        <StatusLine />
        {route.name === "session" ? (
          <SessionView key={route.sessionId} projectId={route.projectId} sessionId={route.sessionId} projectName={projects.data?.find((p) => p.id === route.projectId)?.name} />
        ) : (
          <ProjectView key={activeId ?? "none"} projectId={activeId} projects={projects} />
        )}
      </main>
    </div>
  );
}

function StatusLine() {
  const { workspace } = useDashboard();
  const live = useRealtimeStatus(workspace);
  if (workspace.kind === "preview" || live !== "unavailable") return null;
  return <p className="rd-statusline" role="status">Live updates are unavailable; the workspace refreshes on a timer instead.</p>;
}

function PreviewBanner() {
  const { workspace, reconnect, env } = useDashboard();
  const [confirmReset, setConfirmReset] = useState(false);
  if (workspace.kind !== "preview") return null;
  return (
    <div className="rd-preview-banner" role="note" aria-label="Sample data">
      <p><strong>Sample data.</strong> Fictional recordings for exploring the interface. Nothing here was recorded or analyzed, and edits stay in this browser.</p>
      <div className="rd-preview-actions">
        {confirmReset ? (
          <>
            <span>Discard sample edits?</span>
            <button type="button" className="rd-btn rd-btn--small" onClick={() => { workspace.reset?.(); setConfirmReset(false); window.location.hash = "#/"; }}>Reset</button>
            <button type="button" className="rd-btn rd-btn--ghost rd-btn--small" onClick={() => setConfirmReset(false)}>Keep</button>
          </>
        ) : (
          <button type="button" className="rd-btn rd-btn--ghost rd-btn--small" onClick={() => setConfirmReset(true)}>Reset</button>
        )}
        {env.apiBaseUrl && <button type="button" className="rd-btn rd-btn--small" onClick={reconnect}>Connect to local API</button>}
      </div>
    </div>
  );
}
