import type { DbConnection } from "../spacetime";
import type { ApiClient } from "./http";

export type RealtimeStatus = "connecting" | "live" | "unavailable" | "stopped";
const VIEWS = ["my_projects", "my_sessions", "my_jobs", "my_job_stages", "my_graphs", "my_corrections", "my_session_boards"];

/** Read-only subscriptions invalidate API snapshots; all mutations still go through FastAPI. */
export function createRealtime(client: ApiClient) {
  const listeners = new Set<() => void>();
  const granted = new Set<string>();
  const controller = new AbortController();
  let connection: DbConnection | null = null;
  let identity: string | null = null;
  let started = false;
  let stopped = false;
  let state: RealtimeStatus = "connecting";
  let notifyTimer: ReturnType<typeof setTimeout> | undefined;
  let connectTimer: ReturnType<typeof setTimeout> | undefined;

  const notify = () => {
    if (stopped || notifyTimer) return;
    notifyTimer = setTimeout(() => {
      notifyTimer = undefined;
      for (const listener of listeners) listener();
    }, 75);
  };
  const status = (next: RealtimeStatus) => { state = next; notify(); };
  const fail = () => {
    clearTimeout(connectTimer);
    if (stopped || state === "unavailable") return;
    status("unavailable");
    controller.abort();
    connection?.disconnect();
  };

  async function grant(projectId: string) {
    if (!identity || stopped || granted.has(projectId)) return;
    try {
      await client.post(`/v1/projects/${encodeURIComponent(projectId)}/realtime-viewers`, { identity }, { signal: controller.signal });
      granted.add(projectId);
    } catch (error) { fail(); throw error; }
  }

  async function start() {
    if (started || stopped) return;
    started = true;
    try {
      const config = await client.get<{ backend: string; ready: boolean; uri?: string; database?: string }>("/v1/realtime", { signal: controller.signal });
      if (config.backend !== "spacetimedb" || !config.ready || !config.uri || !config.database) return status("unavailable");
      const uri = new URL(config.uri);
      if (!["https:", "wss:", "http:", "ws:"].includes(uri.protocol)) throw new Error("Unsupported realtime URL");
      // Browsers connecting from HTTPS require an encrypted database connection.
      if (typeof location !== "undefined" && location.protocol === "https:" && ["http:", "ws:"].includes(uri.protocol)) throw new Error("Realtime requires TLS");
      const { DbConnection } = await import("../spacetime");
      if (stopped) return;
      connectTimer = setTimeout(fail, 15_000);
      connection = DbConnection.builder().withUri(config.uri).withDatabaseName(config.database)
        .onConnect((conn, viewer) => {
          identity = viewer.toHexString();
          void (async () => {
            const response = await client.get<{ projects: { id: string }[] } | { id: string }[]>("/v1/projects", { signal: controller.signal });
            const projects = Array.isArray(response) ? response : response.projects;
            // Grants are bounded by the user's current project list and authenticated by FastAPI.
            for (const project of projects) await grant(project.id);
            if (stopped) return;
            const changed = () => notify();
            for (const table of [conn.db.myProjects, conn.db.mySessions, conn.db.myJobs, conn.db.myJobStages, conn.db.myGraphs, conn.db.myCorrections, conn.db.mySessionBoards]) {
              table.onInsert(changed);
              table.onDelete(changed);
              table.onUpdate(changed);
            }
            conn.subscriptionBuilder().onApplied(() => {
              clearTimeout(connectTimer);
              status("live");
            }).onError(fail).subscribe(VIEWS.map((name) => `SELECT * FROM ${name}`));
          })().catch(fail);
        })
        .onConnectError(fail)
        .onDisconnect(() => { if (!stopped) status("unavailable"); })
        .build();
    } catch { fail(); }
  }

  return {
    status: () => state,
    grant,
    subscribe(listener: () => void) {
      listeners.add(listener);
      void start();
      return () => { listeners.delete(listener); };
    },
    async dispose() {
      if (stopped) return;
      stopped = true;
      state = "stopped";
      controller.abort();
      clearTimeout(notifyTimer);
      clearTimeout(connectTimer);
      connection?.disconnect();
      listeners.clear();
      if (identity) {
        const viewer = identity;
        await Promise.allSettled([...granted].map((id) => client.delete(`/v1/projects/${encodeURIComponent(id)}/realtime-viewers`, { body: { identity: viewer } })));
      }
    },
  };
}
