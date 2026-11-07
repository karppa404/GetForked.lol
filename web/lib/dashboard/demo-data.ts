// Deterministic sample workspace for the Preview mode. Every app, task, request and screenshot
// here is fictional illustration — nothing was recorded or analyzed.

import type { Ambiguity, Frame, Graph, GraphEdge, GraphNode, Interaction, NetworkEvent, NetworkStatus, Project, SessionDetail } from "./types";

type Variant = NonNullable<Frame["preview"]>["variant"];

interface Call {
  method: string;
  url: string;
  status: number;
  /** Endpoint node label; calls sharing a label share a node. */
  endpoint: string;
  candidate?: boolean;
}

type Step =
  | { screen: string; variant: Variant }
  | { action: string; kind: "click" | "key" | "scroll"; control: string; role?: string; calls?: Call[] };

interface SessionSeed {
  id: string;
  project_id: string;
  task: string;
  app: { name: string; bundle_id: string };
  started_at: string;
  network_status: NetworkStatus;
  /** false: uploaded but not yet analyzed — run analysis to watch stages publish. */
  analyzed: boolean;
  steps: Step[];
  ambiguities?: (Ambiguity & { at?: string })[];
}

export const PREVIEW_PROJECTS: Project[] = [
  { id: "prj-ledgerly", name: "Ledgerly invoicing", created_at: "2026-10-28T16:20:00Z" },
  { id: "prj-fieldnotes", name: "Field Notes desktop", created_at: "2026-11-01T18:05:00Z" },
];

const LEDGERLY = { name: "Ledgerly", bundle_id: "com.example.ledgerly" };
const FIELDNOTES = { name: "Field Notes", bundle_id: "com.example.fieldnotes" };

const SEEDS: SessionSeed[] = [
  {
    id: "5e55a001-0000-4000-8000-00000000a001",
    project_id: "prj-ledgerly",
    task: "Create and send an invoice",
    app: LEDGERLY,
    started_at: "2026-11-03T15:12:04Z",
    network_status: "observed",
    analyzed: true,
    steps: [
      { screen: "Invoices", variant: "list" },
      { action: "Click “New invoice”", kind: "click", control: "New invoice", role: "AXButton", calls: [{ method: "GET", url: "/api/clients?limit=20", status: 200, endpoint: "GET /api/clients" }] },
      { screen: "Invoice editor", variant: "editor" },
      { action: "Choose client", kind: "click", control: "Client", role: "AXPopUpButton", calls: [{ method: "GET", url: "/api/clients/c_2041", status: 200, endpoint: "GET /api/clients/{id}" }] },
      { action: "Add line item", kind: "click", control: "Add line", role: "AXButton", calls: [{ method: "POST", url: "/api/invoices", status: 201, endpoint: "POST /api/invoices" }] },
      { screen: "Invoice draft", variant: "editor" },
      { action: "Click “Send”", kind: "click", control: "Send", role: "AXButton" },
      { screen: "Send invoice dialog", variant: "dialog" },
      { action: "Confirm send", kind: "key", control: "Return (default button)", calls: [
        { method: "POST", url: "/api/invoices/inv_8812/send", status: 202, endpoint: "POST /api/invoices/{id}/send" },
        { method: "GET", url: "/api/invoices/inv_8812/pdf", status: 200, endpoint: "GET /api/invoices/{id}/pdf", candidate: true },
      ] },
      { screen: "Invoice sent", variant: "confirmation" },
    ],
    ambiguities: [
      { at: "GET /api/invoices/{id}/pdf", message: "PDF request fired 900 ms after send; it may be a background prefetch rather than part of sending." },
      { at: "Add line item", message: "A draft invoice was created when the first line item was added — confirm this is when drafts are saved." },
    ],
  },
  {
    id: "5e55a002-0000-4000-8000-00000000a002",
    project_id: "prj-ledgerly",
    task: "Refund a partial payment",
    app: LEDGERLY,
    started_at: "2026-11-04T10:41:37Z",
    network_status: "none_observed",
    analyzed: true,
    steps: [
      { screen: "Payments", variant: "list" },
      { action: "Open payment #4471", kind: "click", control: "Payment row", role: "AXRow" },
      { screen: "Payment detail", variant: "editor" },
      { action: "Click “Refund”", kind: "click", control: "Refund", role: "AXButton" },
      { screen: "Refund dialog", variant: "dialog" },
      { action: "Set amount", kind: "click", control: "Amount (redacted value)", role: "AXTextField" },
      { action: "Confirm refund", kind: "click", control: "Refund payment", role: "AXButton" },
      { screen: "Refund queued", variant: "confirmation" },
    ],
    ambiguities: [{ at: "Confirm refund", message: "No network requests were observed; the refund may be queued locally and synced later." }],
  },
  {
    id: "5e55a003-0000-4000-8000-00000000a003",
    project_id: "prj-ledgerly",
    task: "Export the monthly report",
    app: LEDGERLY,
    started_at: "2026-11-06T09:02:15Z",
    network_status: "not_captured",
    analyzed: false,
    steps: [
      { screen: "Reports", variant: "list" },
      { action: "Choose “October 2026”", kind: "click", control: "Period", role: "AXPopUpButton" },
      { screen: "Monthly summary", variant: "editor" },
      { action: "Click “Export”", kind: "click", control: "Export", role: "AXButton" },
      { screen: "Export options", variant: "dialog" },
      { action: "Choose CSV and export", kind: "click", control: "Export CSV", role: "AXButton" },
      { screen: "Export complete", variant: "confirmation" },
    ],
  },
  {
    id: "5e55b001-0000-4000-8000-00000000b001",
    project_id: "prj-fieldnotes",
    task: "Tag and archive a note",
    app: FIELDNOTES,
    started_at: "2026-11-02T20:14:50Z",
    network_status: "not_captured",
    analyzed: true,
    steps: [
      { screen: "All notes", variant: "list" },
      { action: "Open “Site visit — Dock 4”", kind: "click", control: "Note row", role: "AXRow" },
      { screen: "Note editor", variant: "editor" },
      { action: "Add tag", kind: "click", control: "Tags", role: "AXButton" },
      { screen: "Tag picker", variant: "dialog" },
      { action: "Choose “inspections”", kind: "click", control: "inspections", role: "AXMenuItem" },
      { action: "Archive note", kind: "key", control: "⌘⌫ shortcut" },
      { screen: "Archive", variant: "list" },
    ],
  },
];

function hex(n: number, width: number) {
  return n.toString(16).padStart(width, "0");
}

function evidenceUuid(sessionIndex: number, n: number) {
  return `e${hex(sessionIndex, 7)}-${hex(n, 4)}-4000-8000-${hex(n * 7919 + sessionIndex, 12)}`;
}

interface BuiltSession {
  detail: Omit<SessionDetail, "job" | "graph" | "corrections" | "board_url" | "status">;
  graph: Graph;
  analyzed: boolean;
}

function build(seed: SessionSeed, sessionIndex: number): BuiltSession {
  let evidenceCounter = 0;
  const nextEvidence = () => evidenceUuid(sessionIndex, ++evidenceCounter);
  const interactions: Interaction[] = [];
  const frames: Frame[] = [];
  const network: NetworkEvent[] = [];
  const nodes: GraphNode[] = [];
  const edges: GraphEdge[] = [];
  const endpointNodes = new Map<string, GraphNode>();
  const labelToId = new Map<string, string>();
  const captureNetwork = seed.network_status === "observed";

  let t = 900;
  let lastFrame: Frame | null = null;
  let prevNode: GraphNode | null = null;
  let prevInteraction: Interaction | null = null;
  const pendingAfter: Interaction[] = [];
  let nodeN = 0;
  let edgeN = 0;
  const addEdge = (source: string, target: string, label: string, evidence: string[], association: "observed" | "candidate" = "observed") =>
    edges.push({ id: `edge-${String(++edgeN).padStart(2, "0")}`, source, target, label, evidence_ids: evidence, association });

  for (const step of seed.steps) {
    if ("screen" in step) {
      const frame: Frame = {
        id: nextEvidence(),
        timestamp_ms: t,
        filename: `frame-${String(frames.length + 1).padStart(3, "0")}.png`,
        width: 1440,
        height: 900,
        preview: { title: step.screen, variant: step.variant },
      };
      frames.push(frame);
      for (const i of pendingAfter.splice(0)) i.after_frame_id = frame.id;
      const node: GraphNode = { id: `node-${String(++nodeN).padStart(2, "0")}`, type: "screen", label: step.screen, evidence_ids: [frame.id] };
      nodes.push(node);
      labelToId.set(step.screen, node.id);
      if (prevNode) addEdge(prevNode.id, node.id, "leads to", prevInteraction ? [prevInteraction.id, frame.id] : [frame.id]);
      prevNode = node;
      lastFrame = frame;
      t += 2100 + ((frames.length * 613) % 900);
    } else {
      const interaction: Interaction = {
        id: nextEvidence(),
        timestamp_ms: t,
        kind: step.kind,
        ...(step.kind === "click" ? { x: 420 + ((t / 7) % 600), y: 180 + ((t / 11) % 500) } : { key: step.control }),
        accessibility: step.role ? { role: step.role, title: step.control } : null,
        before_frame_id: lastFrame?.id,
      };
      interactions.push(interaction);
      pendingAfter.push(interaction);
      const node: GraphNode = { id: `node-${String(++nodeN).padStart(2, "0")}`, type: "action", label: step.action, evidence_ids: [interaction.id] };
      nodes.push(node);
      labelToId.set(step.action, node.id);
      if (prevNode) addEdge(prevNode.id, node.id, step.kind === "key" ? "key press" : "click", [interaction.id]);
      if (captureNetwork) {
        (step.calls ?? []).forEach((call, i) => {
          const event: NetworkEvent = { id: nextEvidence(), timestamp_ms: t + 140 + i * 760, method: call.method, url: `https://api.ledgerly.example${call.url}`, status: call.status };
          network.push(event);
          let endpoint = endpointNodes.get(call.endpoint);
          if (!endpoint) {
            endpoint = { id: `node-${String(++nodeN).padStart(2, "0")}`, type: "endpoint", label: call.endpoint, evidence_ids: [] };
            endpointNodes.set(call.endpoint, endpoint);
            labelToId.set(call.endpoint, endpoint.id);
            nodes.push(endpoint);
          }
          endpoint.evidence_ids.push(event.id);
          addEdge(node.id, endpoint.id, `${call.status}`, [interaction.id, event.id], call.candidate ? "candidate" : "observed");
        });
      }
      prevNode = node;
      prevInteraction = interaction;
      t += 1300 + ((interactions.length * 389) % 700);
    }
  }

  const ambiguities: Ambiguity[] = (seed.ambiguities ?? [])
    .filter((a) => !a.at || labelToId.has(a.at))
    .map((a) => ({ element_id: a.at ? labelToId.get(a.at) : a.element_id, message: a.message }));

  return {
    detail: {
      id: seed.id,
      project_id: seed.project_id,
      task: seed.task,
      app: seed.app,
      started_at: seed.started_at,
      duration_ms: t + 600,
      network_status: seed.network_status,
      interactions,
      frames,
      network: network.sort((a, b) => a.timestamp_ms - b.timestamp_ms),
    },
    graph: { schema_version: 1, nodes, edges, network_status: seed.network_status, ambiguities },
    analyzed: seed.analyzed,
  };
}

export const PREVIEW_SESSIONS: BuiltSession[] = SEEDS.map(build);

export function findPreviewSession(id: string): BuiltSession | undefined {
  return PREVIEW_SESSIONS.find((s) => s.detail.id === id);
}
