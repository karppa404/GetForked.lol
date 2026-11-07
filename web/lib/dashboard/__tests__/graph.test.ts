import { describe, expect, it } from "vitest";
import { PREVIEW_SESSIONS } from "../demo-data";
import { applyCorrections, citationIndex, evidenceItems, layeredLayout, networkView, normalizeGraph, validateGraph, workflowView } from "../graph";
import type { Graph } from "../types";

const evidenceSet = (i: number) => new Set(evidenceItems(PREVIEW_SESSIONS[i].detail).map((e) => e.id));

describe("sample graphs", () => {
  it("every preview graph validates against its own evidence", () => {
    PREVIEW_SESSIONS.forEach((s, i) => {
      const result = validateGraph(s.graph, evidenceSet(i));
      expect(result.errors, s.detail.task).toEqual([]);
    });
  });

  it("only sessions with observed network contain endpoint nodes", () => {
    for (const s of PREVIEW_SESSIONS) {
      const hasEndpoints = s.graph.nodes.some((n) => n.type === "endpoint");
      expect(hasEndpoints).toBe(s.graph.network_status === "observed");
      if (s.graph.network_status !== "observed") expect(s.detail.network).toHaveLength(0);
    }
  });

  it("uses stable ids, so corrections keyed by element id survive reloads", () => {
    expect(PREVIEW_SESSIONS[0].graph.nodes[0]).toMatchObject({ id: "node-01", label: "Invoices" });
    expect(PREVIEW_SESSIONS[0].detail.frames[0].id).toBe("e0000000-0001-4000-8000-000000001eef");
  });
});

describe("validateGraph", () => {
  const base: Graph = {
    schema_version: 1,
    network_status: "not_captured",
    ambiguities: [],
    nodes: [
      { id: "a", type: "screen", label: "A", evidence_ids: ["ev1"] },
      { id: "b", type: "action", label: "B", evidence_ids: [] },
    ],
    edges: [{ id: "e", source: "a", target: "b", label: "", evidence_ids: ["ev1"], association: "observed" }],
  };

  it("rejects dangling edges, duplicate ids and unknown evidence", () => {
    const bad = { ...base, edges: [...base.edges, { id: "a", source: "a", target: "zz", label: "", evidence_ids: ["nope"], association: "observed" }] };
    const r = validateGraph(bad, new Set(["ev1"]));
    expect(r.ok).toBe(false);
    expect(r.errors.join("\n")).toMatch(/Duplicate element id a/);
    expect(r.errors.join("\n")).toMatch(/target zz/);
    expect(r.errors.join("\n")).toMatch(/unknown evidence reference nope/);
  });

  it("rejects network nodes when network was not captured", () => {
    const g = { ...base, nodes: [...base.nodes, { id: "n", type: "endpoint", label: "GET /x", evidence_ids: [] }] };
    expect(validateGraph(g).errors.join()).toMatch(/network node present/);
    expect(validateGraph({ ...g, network_status: "observed" }).ok).toBe(true);
  });

  it("rejects wrong schema versions and empty labels after a correction", () => {
    expect(validateGraph({ ...base, schema_version: 2 }).ok).toBe(false);
    const corrected = applyCorrections(base, [{ element_id: "a", label: " " }]);
    expect(validateGraph(corrected).errors).toContain("Node a: label is empty.");
  });
});

describe("corrections", () => {
  it("relabel nodes and edges without mutating the agent graph", () => {
    const g = PREVIEW_SESSIONS[0].graph;
    const edge = g.edges[0];
    const out = applyCorrections(g, [{ element_id: "node-01", label: "Invoice list" }, { element_id: edge.id, label: "opens" }]);
    expect(out.nodes[0].label).toBe("Invoice list");
    expect(out.edges[0].label).toBe("opens");
    expect(g.nodes[0].label).toBe("Invoices");
    expect(out.nodes.slice(1)).toEqual(g.nodes.slice(1));
  });
});

describe("views and layout", () => {
  it("splits workflow and network, with context actions in the network view", () => {
    const g = PREVIEW_SESSIONS[0].graph;
    const wf = workflowView(g);
    expect(wf.nodes.every((n) => n.type !== "endpoint")).toBe(true);
    const net = networkView(g);
    expect(net.nodes.some((n) => n.type === "endpoint")).toBe(true);
    for (const id of net.contextNodeIds) expect(g.nodes.find((n) => n.id === id)?.type).toBe("action");
    expect(networkView(PREVIEW_SESSIONS[1].graph).nodes).toHaveLength(0);
  });

  it("lays out a chain left to right and survives cycles", () => {
    const pos = layeredLayout([{ id: "a" }, { id: "b" }, { id: "c" }], [{ source: "a", target: "b" }, { source: "b", target: "c" }, { source: "c", target: "a" }]);
    expect(Object.keys(pos)).toHaveLength(3);
    expect(pos.a.x).toBeLessThan(pos.b.x);
    expect(pos.b.x).toBeLessThan(pos.c.x);
  });

  it("indexes which elements cite each evidence item", () => {
    const s = PREVIEW_SESSIONS[0];
    const index = citationIndex(s.graph);
    const firstFrame = s.detail.frames[0].id;
    expect(index.get(firstFrame)).toContain("node-01");
  });
});

describe("normalizeGraph", () => {
  it("coerces loose payloads and rejects non-graphs", () => {
    expect(normalizeGraph(null)).toBeNull();
    const g = normalizeGraph({ nodes: [{ id: "x", label: "X" }], edges: [{ id: "e", source: "x", target: "x", association: "weird" }], network_status: "bogus", ambiguities: ["hm"] });
    expect(g?.nodes[0]).toEqual({ id: "x", type: "screen", label: "X", evidence_ids: [] });
    expect(g?.edges[0].association).toBe("candidate");
    expect(g?.network_status).toBe("not_captured");
    expect(g?.ambiguities[0]).toEqual({ message: "hm" });
  });
});
