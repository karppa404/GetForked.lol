import type { Correction, Pairing, Project, SessionDetail, SessionSummary } from "./types";

export type WorkspaceKind = "preview" | "backend";

export type BoardSaveResult = { status: "saved"; board_url: string | null } | { status: "unsupported" };

/**
 * One interface, two implementations: the real HTTP API (backend.ts) and the clearly labeled
 * local Preview workspace (preview.ts). The UI never switches between them on its own.
 */
export interface Workspace {
  kind: WorkspaceKind;
  listProjects(signal?: AbortSignal): Promise<Project[]>;
  createProject(name: string, signal?: AbortSignal): Promise<Project>;
  listSessions(projectId: string, signal?: AbortSignal): Promise<SessionSummary[]>;
  getSession(sessionId: string, signal?: AbortSignal): Promise<SessionDetail>;
  analyze(sessionId: string, signal?: AbortSignal, rerun?: boolean): Promise<{ job_id: string; status: string }>;
  correctLabel(sessionId: string, elementId: string, label: string, signal?: AbortSignal): Promise<Correction>;
  /** Remove a human correction so the agent label shows again. */
  clearCorrection(sessionId: string, elementId: string, originalLabel: string, signal?: AbortSignal): Promise<void>;
  getGraphExport(sessionId: string, signal?: AbortSignal): Promise<unknown>;
  saveBoardUrl(sessionId: string, url: string | null, signal?: AbortSignal): Promise<BoardSaveResult>;
  createPairing(projectId: string, signal?: AbortSignal): Promise<Pairing>;
  getPairing(pairingId: string, signal?: AbortSignal): Promise<Pairing>;
  approveClaim(pairingId: string, claimId: string, signal?: AbortSignal): Promise<void>;
  /** Fetch a frame image as an object URL the caller must revoke. Null when unavailable. */
  frameImage?(sessionId: string, frameImageUrl: string, signal?: AbortSignal): Promise<string | null>;
  /** Preview storage events or authorized SpacetimeDB subscription changes. */
  subscribe?(listener: () => void): () => void;
  realtimeStatus?(): "connecting" | "live" | "unavailable" | "stopped";
  dispose?(): Promise<void>;
  /** Preview only: pretend a recorder entered the room code. Never available in backend mode. */
  simulateClaim?(pairingId: string): void;
  /** Preview only: wipe locally stored demo edits. */
  reset?(): void;
}
