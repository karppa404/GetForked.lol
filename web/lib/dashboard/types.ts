// Shapes follow docs/INTEGRATION.md (snake_case JSON). Fields the contract does not pin down
// (job stages, corrections, frame image URLs, board URL) are optional and normalized defensively.

export type NetworkStatus = "observed" | "none_observed" | "not_captured";
export type Association = "observed" | "candidate";

export interface GraphNode {
  id: string;
  type: string;
  label: string;
  evidence_ids: string[];
}

export interface GraphEdge {
  id: string;
  source: string;
  target: string;
  label: string;
  evidence_ids: string[];
  association: Association;
}

export interface Ambiguity {
  element_id?: string;
  message: string;
}

export interface Graph {
  schema_version: 1;
  nodes: GraphNode[];
  edges: GraphEdge[];
  network_status: NetworkStatus;
  ambiguities: Ambiguity[];
}

export interface User {
  id?: string;
  email?: string;
  name?: string;
  picture?: string;
}

export interface AuthSession {
  access_token: string;
  user: User;
}

export interface Project {
  id: string;
  name: string;
  created_at?: string;
  session_count?: number;
}

export type SessionStatus = "uploaded" | "queued" | "analyzing" | "analyzed" | "failed" | (string & {});

export interface AppInfo {
  name: string;
  bundle_id?: string;
  pid?: number;
}

export interface SessionSummary {
  id: string;
  project_id: string;
  app: AppInfo;
  started_at: string;
  duration_ms: number;
  status: SessionStatus;
  network_status?: NetworkStatus;
}

export interface Interaction {
  id: string;
  timestamp_ms: number;
  kind: string;
  x?: number;
  y?: number;
  key?: string;
  scroll_dx?: number;
  scroll_dy?: number;
  accessibility?: { role?: string; title?: string; label?: string; [k: string]: unknown } | null;
  before_frame_id?: string;
  after_frame_id?: string;
  delayed_frame_id?: string;
}

export interface Frame {
  id: string;
  timestamp_ms: number;
  filename: string;
  width: number;
  height: number;
  sha256?: string;
  /** Optional, not in contract v1: a fetchable image location (absolute or API-relative). */
  image_url?: string;
  /** Preview workspace only: what the sample illustration should depict. */
  preview?: { title: string; variant: "list" | "editor" | "dialog" | "confirmation" | "settings" };
}

export interface NetworkEvent {
  id: string;
  timestamp_ms: number;
  method: string;
  url: string;
  status?: number;
}

export type JobStatus = "queued" | "running" | "succeeded" | "failed" | (string & {});
export type StageStatus = "pending" | "running" | "done" | "failed" | "skipped" | (string & {});

export interface JobStage {
  name: string;
  label?: string;
  status: StageStatus;
  detail?: string;
}

export interface Job {
  id: string;
  status: JobStatus;
  stages: JobStage[];
  error?: string | null;
}

export interface Correction {
  element_id: string;
  label: string;
  updated_at?: string;
  author?: string;
}

export interface SessionDetail extends SessionSummary {
  analysis_provider?: string;
  interactions: Interaction[];
  frames: Frame[];
  network: NetworkEvent[];
  network_status: NetworkStatus;
  job: Job | null;
  graph: Graph | null;
  corrections: Correction[];
  board_url: string | null;
}

export type EvidenceItem =
  | { kind: "interaction"; id: string; timestamp_ms: number; data: Interaction }
  | { kind: "frame"; id: string; timestamp_ms: number; data: Frame }
  | { kind: "network"; id: string; timestamp_ms: number; data: NetworkEvent };
