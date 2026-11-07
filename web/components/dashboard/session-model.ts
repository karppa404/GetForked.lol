import { applyCorrections, citationIndex, evidenceItems } from "@/lib/dashboard/graph";
import type { Ambiguity, Correction, EvidenceItem, Graph, GraphEdge, GraphNode, SessionDetail } from "@/lib/dashboard/types";

export type Selection = { kind: "element"; id: string } | { kind: "evidence"; id: string } | null;

export type GraphElement = { kind: "node"; node: GraphNode } | { kind: "edge"; edge: GraphEdge };

export interface SessionModel {
  session: SessionDetail;
  /** Agent graph with human corrections applied. */
  graph: Graph | null;
  agentLabel: Map<string, string>;
  /** Only corrections that actually differ from the agent label. */
  edited: Map<string, Correction>;
  evidence: EvidenceItem[];
  evidenceById: Map<string, EvidenceItem>;
  citations: Map<string, string[]>;
  ambiguities: Map<string, Ambiguity[]>;
  elements: Map<string, GraphElement>;
}

export function buildSessionModel(session: SessionDetail, pending: Map<string, string>): SessionModel {
  const agent = session.graph;
  const agentLabel = new Map<string, string>();
  const elements = new Map<string, GraphElement>();
  for (const n of agent?.nodes ?? []) agentLabel.set(n.id, n.label);
  for (const e of agent?.edges ?? []) agentLabel.set(e.id, e.label);

  const merged = new Map(session.corrections.map((c) => [c.element_id, c]));
  for (const [id, label] of pending) merged.set(id, { ...(merged.get(id) ?? {}), element_id: id, label });
  const edited = new Map([...merged].filter(([id, c]) => agentLabel.has(id) && c.label !== agentLabel.get(id)));

  const graph = agent ? applyCorrections(agent, [...edited.values()]) : null;
  for (const n of graph?.nodes ?? []) elements.set(n.id, { kind: "node", node: n });
  for (const e of graph?.edges ?? []) elements.set(e.id, { kind: "edge", edge: e });

  const ambiguities = new Map<string, Ambiguity[]>();
  for (const a of graph?.ambiguities ?? []) {
    const key = a.element_id ?? "";
    ambiguities.set(key, [...(ambiguities.get(key) ?? []), a]);
  }

  const evidence = evidenceItems(session);
  return {
    session,
    graph,
    agentLabel,
    edited,
    evidence,
    evidenceById: new Map(evidence.map((e) => [e.id, e])),
    citations: citationIndex(graph),
    ambiguities,
    elements,
  };
}

export function elementEvidence(model: SessionModel, id: string): string[] {
  const el = model.elements.get(id);
  if (!el) return [];
  return el.kind === "node" ? el.node.evidence_ids : el.edge.evidence_ids;
}

export function elementLabel(el: GraphElement): string {
  return el.kind === "node" ? el.node.label : el.edge.label;
}

export const TYPE_LABEL: Record<string, string> = {
  screen: "Screen",
  action: "Action",
  endpoint: "API endpoint",
  api: "API",
  service: "Service",
  request: "Request",
  decision: "Decision",
};

export function typeLabel(type: string): string {
  return TYPE_LABEL[type] ?? type.replace(/_/g, " ").replace(/^\w/, (c) => c.toUpperCase());
}
