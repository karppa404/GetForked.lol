"use client";

import { useCallback, useEffect, useMemo, useState } from "react";
import { clearAuth, loadAuth, previewChosen, rememberPreviewChoice, saveAuth } from "@/lib/dashboard/auth";
import { createBackendWorkspace } from "@/lib/dashboard/backend";
import { resolveEnvironment, type DashboardEnvironment } from "@/lib/dashboard/config";
import { createApiClient } from "@/lib/dashboard/http";
import { createPreviewStore, createPreviewWorkspace } from "@/lib/dashboard/preview";
import { useRealtimeStatus, useRoute } from "@/lib/dashboard/hooks";
import type { AuthSession } from "@/lib/dashboard/types";
import type { Workspace } from "@/lib/dashboard/workspace";
import { ProjectView } from "./project-view";
import { ProjectsView } from "./projects-view";
import { SessionView } from "./session-view";
import { SignIn } from "./sign-in";
import { Brand, DashboardContext, LoadingBlock, useDashboard, type DashboardContextValue } from "./ui";

type Mode = { kind: "starting" } | { kind: "signin"; notice?: string } | { kind: "preview" } | { kind: "backend"; auth: AuthSession };

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

  // Environment depends on window.location, so decide after mount (the page is client-only).
  useEffect(() => {
    const e = resolveEnvironment(window.location.hostname);
    setEnv(e);
    if (!e.canSignIn || previewChosen()) return setMode({ kind: "preview" });
    const auth = e.apiBaseUrl ? loadAuth(e.apiBaseUrl) : null;
    setMode(auth ? { kind: "backend", auth } : { kind: "signin" });
  }, []);

  const backend = useMemo(() => {
    if (!env?.apiBaseUrl || mode.kind !== "backend") return null;
    const base = env.apiBaseUrl;
    const client = createApiClient({
      baseUrl: base,
      getToken: () => loadAuth(base)?.access_token ?? null,
      onUnauthorized: () => {
        clearAuth(base);
        setMode({ kind: "signin", notice: "Your session ended. Sign in again to continue." });
      },
    });
    return { client, workspace: createBackendWorkspace(client) };
  }, [env?.apiBaseUrl, mode.kind]);

  useEffect(() => () => { void backend?.workspace.dispose?.(); }, [backend]);

  const onSignedIn = useCallback(
    (auth: AuthSession) => {
      if (!env?.apiBaseUrl) return;
      saveAuth(env.apiBaseUrl, auth);
      rememberPreviewChoice(false);
      setMode({ kind: "backend", auth });
    },
    [env?.apiBaseUrl],
  );

  const openPreview = useCallback(() => {
    rememberPreviewChoice(true);
    window.location.hash = "#/";
    setMode({ kind: "preview" });
  }, []);

  const leavePreview = useCallback(() => {
    rememberPreviewChoice(false);
    window.location.hash = "#/";
    setMode({ kind: "signin" });
  }, []);

  const signOut = useCallback(async () => {
    await backend?.workspace.dispose?.();
    if (backend) await backend.client.post("/v1/auth/logout").catch(() => {});
    if (env?.apiBaseUrl) clearAuth(env.apiBaseUrl);
    window.location.hash = "#/";
    setMode({ kind: "signin" });
  }, [env?.apiBaseUrl, backend]);

  const ctx = useMemo<DashboardContextValue | null>(() => {
    if (!env) return null;
    if (mode.kind === "preview") return { workspace: getPreviewWorkspace(), env, user: null, signOut, openPreview, leavePreview };
    if (mode.kind === "backend" && backend) return { workspace: backend.workspace, env, user: mode.auth.user, signOut, openPreview, leavePreview };
    return null;
  }, [env, mode, backend, signOut, openPreview, leavePreview]);

  if (!env || mode.kind === "starting") {
    return (
      <div className="rd-app rd-app--center">
        <LoadingBlock label="Opening workspace" />
      </div>
    );
  }

  if (mode.kind === "signin") {
    return (
      <div className="rd-app">
        <SignIn env={env} notice={mode.notice} onSignedIn={onSignedIn} onOpenPreview={openPreview} />
      </div>
    );
  }

  if (!ctx) return null;
  return (
    <DashboardContext.Provider value={ctx}>
      <div className="rd-app">
        <Shell />
      </div>
    </DashboardContext.Provider>
  );
}

function Shell() {
  const route = useRoute();
  return (
    <>
      <a className="rd-skip" href="#rd-main" onClick={(e) => { e.preventDefault(); document.getElementById("rd-main")?.focus(); }}>Skip to content</a>
      <TopBar />
      <PreviewBanner />
      <main id="rd-main" tabIndex={-1} className="rd-main">
        {route.name === "projects" && <ProjectsView />}
        {route.name === "project" && <ProjectView key={route.projectId} projectId={route.projectId} />}
        {route.name === "session" && <SessionView key={route.sessionId} projectId={route.projectId} sessionId={route.sessionId} />}
      </main>
    </>
  );
}

function TopBar() {
  const { workspace, user, signOut, env } = useDashboard();
  const preview = workspace.kind === "preview";
  const live = useRealtimeStatus(workspace);
  return (
    <header className="rd-topbar">
      <Brand compact />
      <a href="#/" className="rd-topbar-link">Projects</a>
      <div className="rd-topbar-right">
        {preview ? (
          <span className="rd-mode-chip" title="Sample data stored only in this browser">Preview</span>
        ) : (
          <span className="rd-api-host" title={`Connected to ${env.apiBaseUrl}`}>
            <span aria-hidden="true" className="rd-live-dot" />
            {live === "live" ? "Live updates" : live === "connecting" ? "Connecting live updates…" : "API updates"}
          </span>
        )}
        {user && (
          <span className="rd-user">
            <span className="rd-avatar" aria-hidden="true">{(user.name ?? user.email ?? "?").slice(0, 1).toUpperCase()}</span>
            <span className="rd-user-name">{user.name ?? user.email ?? "Signed in"}</span>
          </span>
        )}
        {!preview && <button type="button" className="rd-btn rd-btn--ghost rd-btn--small" onClick={signOut}>Sign out</button>}
      </div>
    </header>
  );
}

function PreviewBanner() {
  const { workspace, env, leavePreview } = useDashboard();
  const [confirmReset, setConfirmReset] = useState(false);
  if (workspace.kind !== "preview") return null;
  return (
    <div className="rd-preview-banner" role="note" aria-label="Preview workspace">
      <span className="rd-preview-dot" aria-hidden="true" />
      <p>
        <strong>Preview workspace.</strong> Sample projects, sessions and graphs for exploring Retrace — nothing here was recorded or analyzed, and edits stay in this browser.
        {!env.canSignIn && " Sign-in isn’t configured on this deployment yet."}
      </p>
      <div className="rd-preview-actions">
        {confirmReset ? (
          <>
            <span>Discard your preview edits?</span>
            <button type="button" className="rd-btn rd-btn--small" onClick={() => { workspace.reset?.(); setConfirmReset(false); window.location.hash = "#/"; }}>Reset</button>
            <button type="button" className="rd-btn rd-btn--ghost rd-btn--small" onClick={() => setConfirmReset(false)}>Keep</button>
          </>
        ) : (
          <button type="button" className="rd-btn rd-btn--ghost rd-btn--small" onClick={() => setConfirmReset(true)}>Reset sample data</button>
        )}
        {env.canSignIn && <button type="button" className="rd-btn rd-btn--small" onClick={leavePreview}>Sign in</button>}
      </div>
    </div>
  );
}

