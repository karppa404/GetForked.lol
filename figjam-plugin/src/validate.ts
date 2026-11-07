// Validation for Retrace Graph v1 JSON (GET /v1/sessions/{id}/graph).
// Pure and dependency-free so it runs both in the plugin sandbox and under `node --test`.

export type NetworkStatus = "observed" | "none_observed" | "not_captured";

export interface GraphNode {
  id: string;
  type: string;
  label: string;
  evidence_ids: string[];
  network_status?: NetworkStatus;
  corrected?: boolean;
  agent_label?: string;
}

export interface GraphEdge {
  id: string;
  source: string;
  target: string;
  label: string;
  evidence_ids: string[];
  association: "observed" | "candidate";
}

export interface Suggestion {
  id: string;
  label: string;
  rationale?: string;
}

export interface Graph {
  schema_version: 1;
  preview_sample?: boolean;
  session_id?: string;
  graph_version?: number;
  nodes: GraphNode[];
  edges: GraphEdge[];
  network_status: NetworkStatus;
  ambiguities: { message: string; element_id?: string }[];
  suggestions: Suggestion[];
}

export interface ValidationResult {
  ok: boolean;
  errors: string[];
  graph?: Graph;
}

const NODE_TYPES = ["screen", "action", "api_call"];
const STATUSES = ["observed", "none_observed", "not_captured"];
const MAX_NODES = 500;
const MAX_EDGES = 1000;
const MAX_LABEL = 300;

function isObj(v: unknown): v is Record<string, unknown> {
  return typeof v === "object" && v !== null && !Array.isArray(v);
}

function strList(v: unknown): string[] | null {
  if (!Array.isArray(v) || !v.every((x) => typeof x === "string")) return null;
  return v as string[];
}

function clean(v: unknown): string {
  const s = typeof v === "string" ? v : "";
  return s.replace(/[\u0000-\u001f\u007f]/g, " ").replace(/\s+/g, " ").trim().slice(0, MAX_LABEL);
}

export function validateGraph(raw: unknown): ValidationResult {
  const errors: string[] = [];
  if (!isObj(raw)) return { ok: false, errors: ["Graph must be a JSON object."] };
  if (raw.schema_version !== 1) errors.push("schema_version must be 1.");
  if (!Array.isArray(raw.nodes)) errors.push("nodes must be an array.");
  if (!Array.isArray(raw.edges)) errors.push("edges must be an array.");
  if (!STATUSES.includes(raw.network_status as string)) errors.push("network_status must be observed, none_observed or not_captured.");
  if (errors.length) return { ok: false, errors };
  const rawNodes = raw.nodes as unknown[];
  const rawEdges = raw.edges as unknown[];
  if (rawNodes.length > MAX_NODES || rawEdges.length > MAX_EDGES) {
    return { ok: false, errors: [`Graph too large (max ${MAX_NODES} nodes, ${MAX_EDGES} edges).`] };
  }

  const nodes: GraphNode[] = [];
  const types = new Map<string, string>();
  rawNodes.forEach((n, i) => {
    if (!isObj(n)) return errors.push(`nodes[${i}] must be an object.`);
    const id = n.id;
    const evidence = strList(n.evidence_ids);
    if (typeof id !== "string" || !id) return errors.push(`nodes[${i}].id is required.`);
    if (types.has(id)) return errors.push(`Duplicate node id ${id}.`);
    if (!NODE_TYPES.includes(n.type as string)) return errors.push(`Node ${id}: unsupported type ${String(n.type)}.`);
    if (!evidence || evidence.length === 0) return errors.push(`Node ${id}: evidence_ids must be a non-empty string array.`);
    types.set(id, n.type as string);
    nodes.push({
      id,
      type: n.type as string,
      label: clean(n.label) || `Untitled ${String(n.type).replace("_", " ")}`,
      evidence_ids: evidence,
      network_status: STATUSES.includes(n.network_status as string) ? (n.network_status as NetworkStatus) : undefined,
      corrected: n.corrected === true,
      agent_label: typeof n.agent_label === "string" ? clean(n.agent_label) : undefined,
    });
  });

  const edges: GraphEdge[] = [];
  const edgeIds = new Set<string>();
  rawEdges.forEach((e, i) => {
    if (!isObj(e)) return errors.push(`edges[${i}] must be an object.`);
    const id = typeof e.id === "string" && e.id ? e.id : `edges[${i}]`;
    if (edgeIds.has(id)) return errors.push(`Duplicate edge id ${id}.`);
    edgeIds.add(id);
    const source = e.source as string;
    const target = e.target as string;
    if (!types.has(source) || !types.has(target)) return errors.push(`Edge ${id}: source/target must reference nodes.`);
    const evidence = strList(e.evidence_ids);
    if (!evidence || evidence.length === 0) return errors.push(`Edge ${id}: evidence_ids must be a non-empty string array.`);
    if (e.association !== "observed" && e.association !== "candidate") return errors.push(`Edge ${id}: association must be observed or candidate.`);
    const touchesApi = types.get(source) === "api_call" || types.get(target) === "api_call";
    if (touchesApi && e.association === "observed") return errors.push(`Edge ${id}: API associations must be candidate.`);
    edges.push({ id, source, target, label: clean(e.label), evidence_ids: evidence, association: e.association });
  });

  const hasApi = nodes.some((n) => n.type === "api_call");
  if (raw.network_status === "not_captured" && hasApi) errors.push("network_status not_captured but API nodes are present.");
  if (raw.network_status === "none_observed" && hasApi) errors.push("network_status none_observed but API nodes are present.");

  const ambiguities = (Array.isArray(raw.ambiguities) ? raw.ambiguities : [])
    .map((a) => (typeof a === "string" ? { message: clean(a) } : isObj(a) ? { message: clean(a.message), element_id: typeof a.element_id === "string" ? a.element_id : undefined } : { message: "" }))
    .filter((a) => a.message)
    .slice(0, 50);
  const suggestions = (Array.isArray(raw.suggestions) ? raw.suggestions : [])
    .filter(isObj)
    .map((s, i) => ({ id: typeof s.id === "string" ? s.id : `suggestion:${i + 1}`, label: clean(s.label), rationale: clean(s.rationale) || undefined }))
    .filter((s) => s.label)
    .slice(0, 30);

  if (errors.length) return { ok: false, errors };
  return {
    ok: true,
    errors: [],
    graph: {
      schema_version: 1,
      preview_sample: raw.preview_sample === true,
      session_id: typeof raw.session_id === "string" ? raw.session_id : undefined,
      graph_version: typeof raw.graph_version === "number" ? raw.graph_version : undefined,
      nodes,
      edges,
      network_status: raw.network_status as NetworkStatus,
      ambiguities,
      suggestions,
    },
  };
}

export interface Placement {
  id: string;
  x: number;
  y: number;
}

/** Deterministic layout: one row per node type, in graph order. */
export function layout(graph: Graph, spacingX = 360, spacingY = 300): Placement[] {
  const rows: Record<string, number> = { screen: 0, action: 1, api_call: 2 };
  const counters: Record<string, number> = { screen: 0, action: 0, api_call: 0 };
  return graph.nodes.map((n) => {
    const col = counters[n.type]++;
    const offset = n.type === "action" ? spacingX / 2 : 0;
    return { id: n.id, x: col * spacingX + offset, y: rows[n.type] * spacingY };
  });
}

export function evidenceCaption(ids: string[], max = 3): string {
  const shown = ids.slice(0, max).map((id) => id.slice(0, 8));
  return `evidence: ${shown.join(", ")}${ids.length > max ? ` +${ids.length - max}` : ""}`;
}
