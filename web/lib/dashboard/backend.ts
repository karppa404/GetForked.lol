import { normalizeGraph, normalizeNetworkStatus } from "./graph";
import { ApiError, type ApiClient } from "./http";
import type { AuthSession, Correction, Job, JobStage, Pairing, PairingClaim, Project, SessionDetail, SessionSummary } from "./types";
import type { Workspace } from "./workspace";

type Raw = Record<string, unknown>;
const obj = (v: unknown): Raw => (v && typeof v === "object" && !Array.isArray(v) ? (v as Raw) : {});
const arr = (v: unknown): unknown[] => (Array.isArray(v) ? v : []);
const s = (v: unknown, f = "") => (typeof v === "string" ? v : f);
const n = (v: unknown, f = 0) => (typeof v === "number" && Number.isFinite(v) ? v : f);
const path = (id: string) => encodeURIComponent(id);

/** Lists may arrive bare or wrapped (`{projects:[...]}`, `{items:[...]}`). */
function list(raw: unknown, key: string): unknown[] {
  if (Array.isArray(raw)) return raw;
  const o = obj(raw);
  return arr(o[key] ?? o.items ?? o.data);
}

export function normalizeProject(raw: unknown): Project {
  const o = obj(raw);
  return { id: s(o.id), name: s(o.name, "Untitled project"), created_at: s(o.created_at) || undefined, session_count: typeof o.session_count === "number" ? o.session_count : undefined };
}

export function normalizeSummary(raw: unknown): SessionSummary {
  const o = obj(raw);
  const app = obj(o.app);
  const job = obj(o.job);
  return {
    id: s(o.id),
    project_id: s(o.project_id),
    task: s(o.task, "Untitled task"),
    app: { name: s(app.name, "Unknown app"), bundle_id: s(app.bundle_id) || undefined },
    started_at: s(o.started_at),
    duration_ms: n(o.duration_ms),
    status: s(o.status) || s(job.status) || "uploaded",
    network_status: o.network_status === undefined ? undefined : normalizeNetworkStatus(o.network_status),
  };
}

function normalizeJob(raw: unknown): Job | null {
  if (!raw || typeof raw !== "object") return null;
  const o = obj(raw);
  const stages: JobStage[] = arr(o.stages).map((st) => {
    const x = obj(st);
    return { name: s(x.name, "stage"), label: s(x.label) || undefined, status: s(x.status, "pending"), detail: s(x.detail) || undefined };
  });
  return { id: s(o.id ?? o.job_id), status: s(o.status, "queued"), stages, error: typeof o.error === "string" ? o.error : null };
}

function normalizeCorrections(raw: unknown): Correction[] {
  if (Array.isArray(raw)) {
    return raw.map(obj).filter((c) => typeof c.element_id === "string" && typeof c.label === "string").map((c) => ({
      element_id: c.element_id as string,
      label: c.label as string,
      updated_at: s(c.updated_at) || undefined,
      author: s(c.author) || undefined,
    }));
  }
  // Map form: {element_id: label | {label}}
  return Object.entries(obj(raw)).flatMap(([element_id, v]) => {
    const label = typeof v === "string" ? v : s(obj(v).label);
    return label ? [{ element_id, label }] : [];
  });
}

export function normalizeSessionDetail(raw: unknown): SessionDetail {
  const o = obj(raw);
  const analysis = obj(o.analysis);
  const manifest = obj(o.manifest);
  const pick = (k: string) => o[k] ?? manifest[k];
  const summary = normalizeSummary({ ...manifest, ...o });
  const graph = normalizeGraph(o.graph ?? analysis.graph);
  const networkStatus = normalizeNetworkStatus(o.network_status ?? graph?.network_status ?? (arr(pick("network")).length ? "observed" : "not_captured"));
  return {
    ...summary,
    network_status: networkStatus,
    interactions: arr(pick("interactions")).map(obj).map((i) => ({ ...(i as object), id: s(i.id), timestamp_ms: n(i.timestamp_ms), kind: s(i.kind, "event") })),
    frames: arr(pick("frames")).map(obj).map((f) => ({
      id: s(f.id),
      timestamp_ms: n(f.timestamp_ms),
      filename: s(f.filename),
      width: n(f.width),
      height: n(f.height),
      sha256: s(f.sha256) || undefined,
      image_url: s(f.image_url ?? f.url) || undefined,
    })),
    network: arr(pick("network")).map(obj).map((e) => ({ id: s(e.id), timestamp_ms: n(e.timestamp_ms), method: s(e.method, "GET"), url: s(e.url), status: typeof e.status === "number" ? e.status : undefined })),
    job: normalizeJob(o.job ?? analysis.job),
    graph,
    corrections: normalizeCorrections(o.corrections ?? analysis.corrections),
    board_url: s(o.board_url) || null,
  };
}

export function normalizePairing(raw: unknown, fallback?: Partial<Pairing>): Pairing {
  const o = obj(raw);
  const claims: PairingClaim[] = arr(o.claims ?? o.pending_claims).map(obj).map((c) => ({ claim_id: s(c.claim_id ?? c.id), device_name: s(c.device_name, "Unnamed device"), status: s(c.status, "pending") }));
  return {
    pairing_id: s(o.pairing_id ?? o.id, fallback?.pairing_id ?? ""),
    code: s(o.code, fallback?.code ?? ""),
    expires_at: s(o.expires_at, fallback?.expires_at ?? ""),
    claims,
  };
}

export function normalizeAuth(raw: unknown): AuthSession {
  const o = obj(raw);
  const token = s(o.access_token);
  if (!token) throw new ApiError("parse", "Sign-in response did not include an access token");
  const u = obj(o.user);
  return { access_token: token, user: { id: s(u.id) || undefined, email: s(u.email) || undefined, name: s(u.name) || undefined, picture: s(u.picture) || undefined } };
}

export function signInWithGoogle(client: ApiClient, credential: string, signal?: AbortSignal) {
  return client.post<unknown>("/v1/auth/google", { credential }, { anonymous: true, signal }).then(normalizeAuth);
}

export function signInForDevelopment(client: ApiClient, signal?: AbortSignal) {
  return client.post<unknown>("/v1/auth/dev", {}, { anonymous: true, signal }).then(normalizeAuth);
}

export function createBackendWorkspace(client: ApiClient): Workspace {
  return {
    kind: "backend",
    async listProjects(signal) {
      return list(await client.get("/v1/projects", { signal }), "projects").map(normalizeProject);
    },
    async createProject(name, signal) {
      return normalizeProject(await client.post("/v1/projects", { name }, { signal }));
    },
    async listSessions(projectId, signal) {
      return list(await client.get(`/v1/projects/${path(projectId)}/sessions`, { signal }), "sessions").map(normalizeSummary);
    },
    async getSession(id, signal) {
      return normalizeSessionDetail(await client.get(`/v1/sessions/${path(id)}`, { signal }));
    },
    async analyze(id, signal) {
      const r = obj(await client.post(`/v1/sessions/${path(id)}/analyze`, {}, { signal }));
      return { job_id: s(r.job_id), status: s(r.status, "queued") };
    },
    async correctLabel(sessionId, elementId, label, signal) {
      const r = obj(await client.put(`/v1/sessions/${path(sessionId)}/corrections/${path(elementId)}`, { label }, { signal }));
      return { element_id: s(r.element_id, elementId), label: s(r.label, label), updated_at: s(r.updated_at) || undefined, author: s(r.author) || undefined };
    },
    async clearCorrection(sessionId, elementId, originalLabel, signal) {
      // The v1 contract has no DELETE; writing the agent's label back is the closest equivalent.
      await client.put(`/v1/sessions/${path(sessionId)}/corrections/${path(elementId)}`, { label: originalLabel }, { signal });
    },
    async getGraphExport(sessionId, signal) {
      return client.get(`/v1/sessions/${path(sessionId)}/graph`, { signal });
    },
    async saveBoardUrl(sessionId, url, signal) {
      // Not in contract v1. Try a conventional endpoint and report "unsupported" honestly.
      try {
        const r = obj(await client.put(`/v1/sessions/${path(sessionId)}/board`, { board_url: url }, { signal }));
        return { status: "saved", board_url: s(r.board_url) || url };
      } catch (error) {
        if (error instanceof ApiError && (error.status === 404 || error.status === 405 || error.status === 501)) return { status: "unsupported" };
        throw error;
      }
    },
    async createPairing(projectId, signal) {
      return normalizePairing(await client.post("/v1/pairings", { project_id: projectId }, { signal }));
    },
    async getPairing(id, signal) {
      return normalizePairing(await client.get(`/v1/pairings/${path(id)}`, { signal }), { pairing_id: id });
    },
    async approveClaim(pairingId, claimId, signal) {
      await client.post(`/v1/pairings/${path(pairingId)}/approve`, { claim_id: claimId }, { signal });
    },
    async frameImage(_sessionId, imageUrl, signal) {
      const isAbsolute = /^https?:\/\//.test(imageUrl);
      if (isAbsolute && !imageUrl.startsWith(client.baseUrl)) return imageUrl; // pre-signed URL from the API
      const rel = isAbsolute ? imageUrl.slice(client.baseUrl.length) : imageUrl;
      const res = await client.request<Response>("GET", rel.startsWith("/") ? rel : `/${rel}`, { signal, raw: true });
      return URL.createObjectURL(await res.blob());
    },
  };
}
