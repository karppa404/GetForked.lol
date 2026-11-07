// FigJam plugin sandbox: imports a validated Retrace graph as editable shapes and connectors.
// Every element carries its evidence IDs in plugin data (key "retrace") and a short caption.
import { evidenceCaption, layout, validateGraph, type Graph } from "./validate.ts";

figma.showUI(__html__, { width: 380, height: 420 });

const SHAPES: Record<string, ShapeWithTextNode["shapeType"]> = {
  screen: "ROUNDED_RECTANGLE",
  action: "ELLIPSE",
  api_call: "SQUARE",
};
const COLORS: Record<string, RGB> = {
  screen: { r: 0.85, g: 0.92, b: 1 },
  action: { r: 0.88, g: 0.97, b: 0.88 },
  api_call: { r: 1, g: 0.94, b: 0.82 },
};

async function importGraph(graph: Graph): Promise<number> {
  await figma.loadFontAsync({ family: "Inter", style: "Medium" });
  const created: SceneNode[] = [];
  const byId = new Map<string, ShapeWithTextNode>();
  const origin = figma.viewport.center;
  for (const p of layout(graph)) {
    const n = graph.nodes.find((x) => x.id === p.id)!;
    const shape = figma.createShapeWithText();
    shape.shapeType = SHAPES[n.type];
    shape.resize(280, 160);
    shape.x = origin.x + p.x;
    shape.y = origin.y + p.y;
    shape.fills = [{ type: "SOLID", color: COLORS[n.type] }];
    await figma.loadFontAsync(shape.text.fontName as FontName);
    const network = n.type === "action" && n.network_status ? `\nnetwork: ${n.network_status}` : "";
    shape.text.characters = `${n.label}${n.corrected ? " ✎" : ""}\n${evidenceCaption(n.evidence_ids)}${network}`;
    shape.name = `${n.type}: ${n.label}`;
    shape.setPluginData("retrace", JSON.stringify({ id: n.id, type: n.type, evidence_ids: n.evidence_ids }));
    shape.setSharedPluginData("retrace", "element_id", n.id);
    shape.setSharedPluginData("retrace", "evidence_ids", n.evidence_ids.join(","));
    byId.set(n.id, shape);
    created.push(shape);
  }
  for (const e of graph.edges) {
    const c = figma.createConnector();
    c.connectorStart = { endpointNodeId: byId.get(e.source)!.id, magnet: "AUTO" };
    c.connectorEnd = { endpointNodeId: byId.get(e.target)!.id, magnet: "AUTO" };
    c.connectorEndStrokeCap = "ARROW_LINES";
    if (e.association === "candidate") c.dashPattern = [10, 6];
    await figma.loadFontAsync(c.text.fontName as FontName);
    c.text.characters = `${e.label ? e.label + " " : ""}(${e.association})`;
    c.name = `${e.association}: ${e.source} → ${e.target}`;
    c.setPluginData("retrace", JSON.stringify({ id: e.id, association: e.association, evidence_ids: e.evidence_ids }));
    c.setSharedPluginData("retrace", "element_id", e.id);
    c.setSharedPluginData("retrace", "evidence_ids", e.evidence_ids.join(","));
    created.push(c);
  }
  const notes: [string, string][] = [
    [`Network: ${graph.network_status}`, graph.network_status === "not_captured" ? "Network capture did not run; API calls are unknown, not absent." : ""],
    ...graph.ambiguities.map((a): [string, string] => ["Ambiguity", a.message]),
    ...graph.suggestions.map((s): [string, string] => ["Suggestion (not observed)", s.label + (s.rationale ? ` — ${s.rationale}` : "")]),
  ];
  let y = origin.y;
  for (const [title, body] of notes) {
    const sticky = figma.createSticky();
    await figma.loadFontAsync(sticky.text.fontName as FontName);
    sticky.text.characters = body ? `${title}\n${body}` : title;
    sticky.x = origin.x - 320;
    sticky.y = y;
    y += 260;
    created.push(sticky);
  }
  figma.currentPage.selection = created;
  figma.viewport.scrollAndZoomIntoView(created);
  return created.length;
}

figma.ui.onmessage = async (msg: { type: string; text?: string }) => {
  if (msg.type === "cancel") return figma.closePlugin();
  if (msg.type !== "import" || typeof msg.text !== "string") return;
  let parsed: unknown;
  try {
    parsed = JSON.parse(msg.text);
  } catch {
    figma.ui.postMessage({ type: "result", ok: false, errors: ["File is not valid JSON."] });
    return;
  }
  const result = validateGraph(parsed);
  if (!result.ok || !result.graph) {
    figma.ui.postMessage({ type: "result", ok: false, errors: result.errors.slice(0, 20) });
    return;
  }
  try {
    const count = await importGraph(result.graph);
    figma.ui.postMessage({ type: "result", ok: true, count });
    figma.notify(`Imported ${result.graph.nodes.length} nodes and ${result.graph.edges.length} connectors`);
  } catch (err) {
    figma.ui.postMessage({ type: "result", ok: false, errors: [String(err)] });
  }
};
