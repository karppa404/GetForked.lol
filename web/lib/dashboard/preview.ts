// Preview workspace: deterministic sample data + local edits persisted in localStorage under a
// clearly demo-labeled key. Two tabs stay in sync through `storage` events. This is a design
// preview, never a stand-in for the real API.

import { PREVIEW_PROJECTS, PREVIEW_SESSIONS, findPreviewSession } from "./demo-data";
import { applyCorrections, workflowView } from "./graph";
import type { Correction, Graph, Job, JobStage, Project, SessionDetail, SessionSummary } from "./types";
import type { Workspace } from "./workspace";

export const PREVIEW_STORAGE_KEY = "retrace.preview-workspace.v1";
export const PREVIEW_STAGE_MS = 3000;

export interface PreviewDelta {
  version: 1;
  /** Marker so anyone inspecting storage sees this is sample data. */
  demo: "Retrace preview workspace — sample data only";
  projects: Project[];
  corrections: Record<string, Record<string, Correction>>;
  boardUrls: Record<string, string>;
  jobs: Record<string, { job_id: string; started_at: number }>;
}

const emptyDelta = (): PreviewDelta => ({
  version: 1,
  demo: "Retrace preview workspace — sample data only",
  projects: [],
  corrections: {},
  boardUrls: {},
  jobs: {},
});

type StorageLike = Pick<Storage, "getItem" | "setItem" | "removeItem">;

export function parseDelta(raw: string | null): PreviewDelta {
  if (!raw) return emptyDelta();
  try {
    const v = JSON.parse(raw) as Partial<PreviewDelta>;
    if (v?.version !== 1) return emptyDelta();
    return {
      ...emptyDelta(),
      projects: Array.isArray(v.projects) ? v.projects.filter((p) => p && typeof p.id === "string" && typeof p.name === "string") : [],
      corrections: v.corrections && typeof v.corrections === "object" ? v.corrections : {},
      boardUrls: v.boardUrls && typeof v.boardUrls === "object" ? v.boardUrls : {},
      jobs: v.jobs && typeof v.jobs === "object" ? v.jobs : {},
    };
  } catch {
    return emptyDelta();
  }
}

export function createPreviewStore(storage: StorageLike | null, eventTarget: Pick<Window, "addEventListener" | "removeEventListener"> | null) {
  let memory = emptyDelta();
  const listeners = new Set<() => void>();
  const read = (): PreviewDelta => {
    if (!storage) return memory;
    try {
      return parseDelta(storage.getItem(PREVIEW_STORAGE_KEY));
    } catch {
      return memory;
    }
  };
  const notify = () => listeners.forEach((l) => l());
  const write = (mutate: (d: PreviewDelta) => void) => {
    const next = read();
    mutate(next);
    memory = next;
    try {
      storage?.setItem(PREVIEW_STORAGE_KEY, JSON.stringify(next));
    } catch {
      // Storage full/blocked: keep the in-memory copy so the session still works.
    }
    notify();
  };
  const onStorage = (e: Event) => {
    const key = (e as StorageEvent).key;
    if (key === PREVIEW_STORAGE_KEY || key === null) notify();
  };
  return {
    read,
    write,
    reset() {
      memory = emptyDelta();
      try {
        storage?.removeItem(PREVIEW_STORAGE_KEY);
      } catch {}
      notify();
    },
    subscribe(listener: () => void) {
      if (listeners.size === 0) eventTarget?.addEventListener("storage", onStorage);
      listeners.add(listener);
      return () => {
        listeners.delete(listener);
        if (listeners.size === 0) eventTarget?.removeEventListener("storage", onStorage);
      };
    },
  };
}

export type PreviewStore = ReturnType<typeof createPreviewStore>;

const STAGES = [
  { name: "ingest", label: "Validate evidence" },
  { name: "workflow", label: "Map workflow" },
  { name: "network", label: "Trace network" },
  { name: "reconcile", label: "Reconcile" },
  { name: "publish", label: "Publish graph" },
] as const;

/** Stage progress is a pure function of elapsed time so every tab computes the same state. */
export function simulatedJob(jobId: string, startedAt: number, now: number, networkCaptured: boolean): Job {
  const elapsed = now - startedAt;
  let k = 0;
  const stages: JobStage[] = STAGES.map((s) => {
    if (s.name === "network" && !networkCaptured) return { ...s, status: "skipped", detail: "Network not captured for this session" };
    const status = elapsed >= (k + 1) * PREVIEW_STAGE_MS ? "done" : elapsed >= k * PREVIEW_STAGE_MS ? "running" : "pending";
    k++;
    return { ...s, status };
  });
  const finished = stages.every((s) => s.status === "done" || s.status === "skipped");
  return { id: jobId, status: finished ? "succeeded" : elapsed < 300 ? "queued" : "running", stages };
}

/** Incremental publication: the workflow appears first, then network, then ambiguities. */
export function publishedGraph(full: Graph, job: Job): Graph | null {
  const done = (name: string) => job.stages.some((s) => s.name === name && (s.status === "done" || s.status === "skipped"));
  if (!done("workflow")) return null;
  if (!done("network") || !done("reconcile")) {
    const view = done("network") ? full : { ...full, ...workflowView(full) };
    return { ...full, nodes: view.nodes, edges: view.edges, ambiguities: [] };
  }
  return done("publish") ? full : { ...full, ambiguities: [] };
}

const delay = (ms: number, signal?: AbortSignal) =>
  new Promise<void>((resolve, reject) => {
    const t = setTimeout(resolve, ms);
    signal?.addEventListener("abort", () => {
      clearTimeout(t);
      reject(new DOMException("Aborted", "AbortError"));
    }, { once: true });
  });

export function createPreviewWorkspace(store: PreviewStore, now: () => number = () => Date.now(), latencyMs = 120): Workspace {
  const sessionDetail = (id: string): SessionDetail => {
    const built = findPreviewSession(id);
    if (!built) throw new Error("Sample session not found");
    const delta = store.read();
    const jobRec = delta.jobs[id];
    const captured = built.detail.network_status !== "not_captured";
    let job: Job | null = null;
    let graph: Graph | null = built.analyzed ? built.graph : null;
    if (jobRec) {
      job = simulatedJob(jobRec.job_id, jobRec.started_at, now(), captured);
      if (!built.analyzed) graph = publishedGraph(built.graph, job);
    } else if (built.analyzed) {
      job = simulatedJob("job-sample", 0, Number.MAX_SAFE_INTEGER, captured);
    }
    const running = job && job.status !== "succeeded";
    return {
      ...built.detail,
      status: running ? "analyzing" : graph ? "analyzed" : "uploaded",
      job,
      graph,
      corrections: Object.values(delta.corrections[id] ?? {}),
      board_url: delta.boardUrls[id] ?? null,
    };
  };

  return {
    kind: "preview",
    async listProjects(signal) {
      await delay(latencyMs, signal);
      const custom = store.read().projects;
      return [...PREVIEW_PROJECTS, ...custom].map((p) => ({ ...p, session_count: PREVIEW_SESSIONS.filter((s) => s.detail.project_id === p.id).length }));
    },
    async createProject(name, signal) {
      await delay(latencyMs, signal);
      const project: Project = { id: `prj-local-${now().toString(36)}`, name: name.trim(), created_at: new Date(now()).toISOString(), session_count: 0 };
      store.write((d) => d.projects.push(project));
      return project;
    },
    async listSessions(projectId, signal) {
      await delay(latencyMs, signal);
      const all = [...PREVIEW_PROJECTS, ...store.read().projects];
      if (!all.some((p) => p.id === projectId)) throw new Error("Project not found in this preview workspace");
      return PREVIEW_SESSIONS.filter((s) => s.detail.project_id === projectId).map((s): SessionSummary => {
        const d = sessionDetail(s.detail.id);
        return { id: d.id, project_id: d.project_id, app: d.app, started_at: d.started_at, duration_ms: d.duration_ms, status: d.status, network_status: d.network_status };
      });
    },
    async getSession(id, signal) {
      await delay(latencyMs / 2, signal);
      return sessionDetail(id);
    },
    async analyze(id, signal) {
      await delay(latencyMs, signal);
      if (!findPreviewSession(id)) throw new Error("Sample session not found");
      const job_id = `job-preview-${now().toString(36)}`;
      store.write((d) => {
        d.jobs[id] = { job_id, started_at: now() };
      });
      return { job_id, status: "queued" };
    },
    async correctLabel(sessionId, elementId, label, signal) {
      await delay(latencyMs, signal);
      const correction: Correction = { element_id: elementId, label: label.trim(), updated_at: new Date(now()).toISOString(), author: "You (preview)" };
      store.write((d) => {
        d.corrections[sessionId] = { ...(d.corrections[sessionId] ?? {}), [elementId]: correction };
      });
      return correction;
    },
    async clearCorrection(sessionId, elementId, _original, signal) {
      await delay(latencyMs, signal);
      store.write((d) => {
        if (d.corrections[sessionId]) delete d.corrections[sessionId][elementId];
      });
    },
    async getGraphExport(sessionId, signal) {
      await delay(latencyMs, signal);
      const d = sessionDetail(sessionId);
      if (!d.graph) throw new Error("This session has no published graph yet.");
      return { ...applyCorrections(d.graph, d.corrections), preview_sample: true };
    },
    async saveBoardUrl(sessionId, url, signal) {
      await delay(latencyMs, signal);
      store.write((d) => {
        if (url) d.boardUrls[sessionId] = url;
        else delete d.boardUrls[sessionId];
      });
      return { status: "saved", board_url: url };
    },
    subscribe: store.subscribe,
    reset: store.reset,
  };
}
