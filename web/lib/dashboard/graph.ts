import type {
  Ambiguity,
  Correction,
  EvidenceItem,
  Graph,
  GraphEdge,
  GraphNode,
  NetworkStatus,
  SessionDetail,
} from "./types";

const NETWORK_TYPES = new Set(["api", "endpoint", "request", "service", "network", "api_call", "host"]);
const NETWORK_STATUSES: NetworkStatus[] = ["observed", "none_observed", "not_captured"];

export function isNetworkNode(node: Pick<GraphNode, "type">): boolean {
  return NETWORK_TYPES.has(node.type.toLowerCase());
}

const str = (v: unknown, fallback = ""): string => (typeof v === "string" ? v : fallback);
const strArr = (v: unknown): string[] => (Array.isArray(v) ? v.filter((x): x is string => typeof x === "string") : []);

export function normalizeNetworkStatus(v: unknown): NetworkStatus {
  return NETWORK_STATUSES.includes(v as NetworkStatus) ? (v as NetworkStatus) : "not_captured";
}

/** Coerce an untrusted graph payload into Graph v1 shape. Returns null if it isn't graph-like. */
export function normalizeGraph(raw: unknown): Graph | null {
  if (!raw || typeof raw !== "object") return null;
  const g = raw as Record<string, unknown>;
  if (!Array.isArray(g.nodes)) return null;
  const nodes: GraphNode[] = g.nodes.map((n) => {
    const o = (n ?? {}) as Record<string, unknown>;
    return { id: str(o.id), type: str(o.type, "screen"), label: str(o.label), evidence_ids: strArr(o.evidence_ids) };
  });
  const edges: GraphEdge[] = (Array.isArray(g.edges) ? g.edges : []).map((e) => {
    const o = (e ?? {}) as Record<string, unknown>;
    return {
      id: str(o.id),
      source: str(o.source),
      target: str(o.target),
      label: str(o.label),
      evidence_ids: strArr(o.evidence_ids),
      association: o.association === "observed" ? "observed" : "candidate",
    };
  });
  const ambiguities: Ambiguity[] = (Array.isArray(g.ambiguities) ? g.ambiguities : []).map((a) => {
    if (typeof a === "string") return { message: a };
    const o = (a ?? {}) as Record<string, unknown>;
    return { element_id: typeof o.element_id === "string" ? o.element_id : undefined, message: str(o.message, str(o.description, "Unresolved ambiguity")) };
  });
  return { schema_version: 1, nodes, edges, network_status: normalizeNetworkStatus(g.network_status), ambiguities };
}

export interface ValidationResult {
  ok: boolean;
  errors: string[];
  warnings: string[];
}

/**
 * Structural validation before export. Mirrors the publisher rules in INTEGRATION.md:
 * unique ids, edges reference nodes, evidence references resolve, and network elements only
 * when network activity was observed. Proposed (candidate) elements must not claim "observed".
 */
export function validateGraph(raw: unknown, evidenceIds?: ReadonlySet<string>): ValidationResult {
  const errors: string[] = [];
  const warnings: string[] = [];
  if (!raw || typeof raw !== "object") return { ok: false, errors: ["Graph is missing or not an object."], warnings };
  const g = raw as Record<string, unknown>;
  if (g.schema_version !== 1) errors.push(`Unsupported schema_version ${JSON.stringify(g.schema_version)} (expected 1).`);
  if (!Array.isArray(g.nodes)) errors.push("nodes must be an array.");
  if (!Array.isArray(g.edges)) errors.push("edges must be an array.");
  if (!NETWORK_STATUSES.includes(g.network_status as NetworkStatus)) errors.push(`network_status must be one of ${NETWORK_STATUSES.join(", ")}.`);
  if (g.ambiguities !== undefined && !Array.isArray(g.ambiguities)) errors.push("ambiguities must be an array.");
  if (errors.length) return { ok: false, errors, warnings };

  const ids = new Set<string>();
  const nodeIds = new Set<string>();
  const checkEvidence = (owner: string, list: unknown) => {
    if (!Array.isArray(list)) {
      errors.push(`${owner}: evidence_ids must be an array.`);
      return;
    }
    if (!evidenceIds) return;
    for (const id of list) if (!evidenceIds.has(id as string)) errors.push(`${owner}: unknown evidence reference ${String(id)}.`);
  };

  for (const n of g.nodes as Record<string, unknown>[]) {
    const id = n?.id;
    if (typeof id !== "string" || !id) {
      errors.push("A node is missing an id.");
      continue;
    }
    if (ids.has(id)) errors.push(`Duplicate element id ${id}.`);
    ids.add(id);
    nodeIds.add(id);
    if (typeof n.label !== "string" || !n.label.trim()) errors.push(`Node ${id}: label is empty.`);
    if (typeof n.type !== "string") errors.push(`Node ${id}: type is missing.`);
    checkEvidence(`Node ${id}`, n.evidence_ids);
    if (typeof n.type === "string" && isNetworkNode({ type: n.type }) && g.network_status !== "observed") {
      errors.push(`Node ${id}: network node present but network_status is ${String(g.network_status)}.`);
    }
  }
  for (const e of g.edges as Record<string, unknown>[]) {
    const id = e?.id;
    if (typeof id !== "string" || !id) {
      errors.push("An edge is missing an id.");
      continue;
    }
    if (ids.has(id)) errors.push(`Duplicate element id ${id}.`);
    ids.add(id);
    if (!nodeIds.has(e.source as string)) errors.push(`Edge ${id}: source ${String(e.source)} is not a node.`);
    if (!nodeIds.has(e.target as string)) errors.push(`Edge ${id}: target ${String(e.target)} is not a node.`);
    if (e.association !== "observed" && e.association !== "candidate") errors.push(`Edge ${id}: association must be observed or candidate.`);
    checkEvidence(`Edge ${id}`, e.evidence_ids);
    if (e.association === "observed" && Array.isArray(e.evidence_ids) && e.evidence_ids.length === 0) {
      warnings.push(`Edge ${id} is marked observed but cites no evidence.`);
    }
  }
  return { ok: errors.length === 0, errors, warnings };
}

export function correctionMap(corrections: Correction[]): Map<string, Correction> {
  return new Map(corrections.map((c) => [c.element_id, c]));
}

/** Human corrections are separate records; apply them over agent labels without mutating. */
export function applyCorrections(graph: Graph, corrections: Correction[]): Graph {
  const map = correctionMap(corrections);
  if (!map.size) return graph;
  const relabel = <T extends { id: string; label: string }>(el: T): T => {
    const c = map.get(el.id);
    return c ? { ...el, label: c.label } : el;
  };
  return { ...graph, nodes: graph.nodes.map(relabel), edges: graph.edges.map(relabel) };
}

export interface GraphView {
  nodes: GraphNode[];
  edges: GraphEdge[];
  /** Workflow nodes shown in the network view only for context (the action that made a call). */
  contextNodeIds: Set<string>;
}

export function workflowView(graph: Graph): GraphView {
  const nodes = graph.nodes.filter((n) => !isNetworkNode(n));
  const ids = new Set(nodes.map((n) => n.id));
  return { nodes, edges: graph.edges.filter((e) => ids.has(e.source) && ids.has(e.target)), contextNodeIds: new Set() };
}

export function networkView(graph: Graph): GraphView {
  if (graph.network_status !== "observed") return { nodes: [], edges: [], contextNodeIds: new Set() };
  const netIds = new Set(graph.nodes.filter(isNetworkNode).map((n) => n.id));
  const edges = graph.edges.filter((e) => netIds.has(e.source) || netIds.has(e.target));
  const contextNodeIds = new Set<string>();
  for (const e of edges) {
    if (!netIds.has(e.source)) contextNodeIds.add(e.source);
    if (!netIds.has(e.target)) contextNodeIds.add(e.target);
  }
  const nodes = graph.nodes.filter((n) => netIds.has(n.id) || contextNodeIds.has(n.id));
  return { nodes, edges, contextNodeIds };
}

/**
 * Deterministic layered layout (longest-path ranking, cycles broken by input order).
 * Good enough for demonstrated single-task workflows; no layout dependency needed.
 */
export function layeredLayout(
  nodes: Pick<GraphNode, "id">[],
  edges: Pick<GraphEdge, "source" | "target">[],
  opts: { rankGap?: number; rowGap?: number; direction?: "LR" | "TB" } = {},
): Record<string, { x: number; y: number }> {
  const { rankGap = 270, rowGap = 120, direction = "LR" } = opts;
  const order = new Map(nodes.map((n, i) => [n.id, i]));
  const preds = new Map<string, string[]>(nodes.map((n) => [n.id, []]));
  const succs = new Map<string, string[]>(nodes.map((n) => [n.id, []]));
  for (const e of edges) {
    if (!order.has(e.source) || !order.has(e.target) || e.source === e.target) continue;
    preds.get(e.target)!.push(e.source);
    succs.get(e.source)!.push(e.target);
  }
  // Kahn's algorithm; when stuck on a cycle, release the earliest remaining node.
  const indeg = new Map(nodes.map((n) => [n.id, preds.get(n.id)!.length]));
  const rank = new Map<string, number>();
  const done = new Set<string>();
  while (done.size < nodes.length) {
    let ready = nodes.filter((n) => !done.has(n.id) && indeg.get(n.id)! <= 0);
    if (!ready.length) ready = [nodes.filter((n) => !done.has(n.id))[0]];
    for (const n of ready) {
      const r = Math.max(0, ...preds.get(n.id)!.filter((p) => done.has(p)).map((p) => rank.get(p)! + 1));
      rank.set(n.id, r);
      done.add(n.id);
      for (const s of succs.get(n.id)!) indeg.set(s, indeg.get(s)! - 1);
    }
  }
  const rows = new Map<number, string[]>();
  for (const n of nodes) {
    const r = rank.get(n.id)!;
    if (!rows.has(r)) rows.set(r, []);
    rows.get(r)!.push(n.id);
  }
  const positions: Record<string, { x: number; y: number }> = {};
  for (const [r, ids] of rows) {
    ids.forEach((id, i) => {
      const offset = (i - (ids.length - 1) / 2) * rowGap;
      positions[id] = direction === "LR" ? { x: r * rankGap, y: offset } : { x: offset * 2.2, y: r * rowGap };
    });
  }
  return positions;
}

export function evidenceItems(session: Pick<SessionDetail, "interactions" | "frames" | "network">): EvidenceItem[] {
  const items: EvidenceItem[] = [
    ...session.interactions.map((d) => ({ kind: "interaction" as const, id: d.id, timestamp_ms: d.timestamp_ms, data: d })),
    ...session.frames.map((d) => ({ kind: "frame" as const, id: d.id, timestamp_ms: d.timestamp_ms, data: d })),
    ...session.network.map((d) => ({ kind: "network" as const, id: d.id, timestamp_ms: d.timestamp_ms, data: d })),
  ];
  const rank = { frame: 0, interaction: 1, network: 2 };
  return items.sort((a, b) => a.timestamp_ms - b.timestamp_ms || rank[a.kind] - rank[b.kind]);
}

/** evidence id -> graph element ids that cite it */
export function citationIndex(graph: Graph | null): Map<string, string[]> {
  const index = new Map<string, string[]>();
  if (!graph) return index;
  for (const el of [...graph.nodes, ...graph.edges]) {
    for (const ev of el.evidence_ids) {
      if (!index.has(ev)) index.set(ev, []);
      index.get(ev)!.push(el.id);
    }
  }
  return index;
}

export function formatTimestamp(ms: number): string {
  const total = Math.max(0, Math.round(ms / 1000));
  return `${String(Math.floor(total / 60)).padStart(2, "0")}:${String(total % 60).padStart(2, "0")}`;
}

export function formatDuration(ms: number): string {
  const s = Math.round(ms / 1000);
  return s < 60 ? `${s}s` : `${Math.floor(s / 60)}m ${String(s % 60).padStart(2, "0")}s`;
}

export function exportFilename(session: Pick<SessionDetail, "id" | "task">): string {
  const slug = session.task.toLowerCase().replace(/[^a-z0-9]+/g, "-").replace(/^-|-$/g, "").slice(0, 48) || "session";
  return `retrace-${slug}-${session.id.slice(0, 8)}.graph.json`;
}
