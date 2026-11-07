import { test } from "node:test";
import assert from "node:assert/strict";
import { evidenceCaption, layout, validateGraph } from "../src/validate.ts";

const good = {
  schema_version: 1,
  session_id: "s",
  nodes: [
    { id: "screen:f1", type: "screen", label: "Orders", evidence_ids: ["f1"] },
    { id: "action:i1", type: "action", label: "Click Save", evidence_ids: ["i1"], network_status: "observed" },
    { id: "api_call:n1", type: "api_call", label: "POST /orders", evidence_ids: ["n1"] },
  ],
  edges: [
    { id: "edge:a", source: "screen:f1", target: "action:i1", label: "", evidence_ids: ["i1"], association: "observed" },
    { id: "edge:b", source: "action:i1", target: "api_call:n1", label: "followed by", evidence_ids: ["i1", "n1"], association: "candidate" },
  ],
  network_status: "observed",
  ambiguities: ["plain string", { message: "object form", element_id: "screen:f1" }],
  suggestions: [{ id: "suggestion:1", kind: "suggestion", label: "Batch the API calls" }],
};

test("accepts a backend graph", () => {
  const r = validateGraph(good);
  assert.equal(r.ok, true, r.errors.join("; "));
  assert.equal(r.graph!.ambiguities.length, 2);
  assert.equal(r.graph!.suggestions[0].label, "Batch the API calls");
});

test("rejects missing evidence, dangling edges and observed API edges", () => {
  const bad = structuredClone(good) as any;
  bad.nodes[0].evidence_ids = [];
  assert.equal(validateGraph(bad).ok, false);
  const dangling = structuredClone(good) as any;
  dangling.edges[0].target = "screen:missing";
  assert.equal(validateGraph(dangling).ok, false);
  const observedApi = structuredClone(good) as any;
  observedApi.edges[1].association = "observed";
  assert.match(validateGraph(observedApi).errors.join(), /candidate/);
  const notCaptured = structuredClone(good) as any;
  notCaptured.network_status = "not_captured";
  assert.equal(validateGraph(notCaptured).ok, false);
  assert.equal(validateGraph({ schema_version: 2, nodes: [], edges: [], network_status: "observed" }).ok, false);
  assert.equal(validateGraph("nope").ok, false);
});

test("cleans labels and lays out rows by type", () => {
  const g = structuredClone(good) as any;
  g.nodes[0].label = "a\u0000b\n\nc";
  const r = validateGraph(g);
  assert.equal(r.graph!.nodes[0].label, "a b c");
  const pos = layout(r.graph!);
  assert.deepEqual(pos.map((p) => p.y), [0, 300, 600]);
  assert.equal(evidenceCaption(["0123456789", "b", "c", "d"]), "evidence: 01234567, b, c +1");
});

test("accepts a graph produced by the backend (offline provider, with a correction)", async () => {
  const { readFile } = await import("node:fs/promises");
  const raw = JSON.parse(await readFile(new URL("./fixtures/backend-graph.json", import.meta.url), "utf8"));
  const r = validateGraph(raw);
  assert.equal(r.ok, true, r.errors.join("; "));
  assert.equal(r.graph!.nodes.some((n) => n.corrected && n.label === "Corrected label"), true);
});
