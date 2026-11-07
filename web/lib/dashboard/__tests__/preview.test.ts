import { describe, expect, it } from "vitest";
import { PREVIEW_STAGE_MS, PREVIEW_STORAGE_KEY, createPreviewStore, createPreviewWorkspace, parseDelta } from "../preview";

class MemoryStorage {
  map = new Map<string, string>();
  getItem(k: string) { return this.map.get(k) ?? null; }
  setItem(k: string, v: string) { this.map.set(k, v); }
  removeItem(k: string) { this.map.delete(k); }
}

/** Two "tabs" sharing one storage; storage events are dispatched to the other tab only, like browsers do. */
function twoTabs() {
  const storage = new MemoryStorage();
  const tabA = new EventTarget();
  const tabB = new EventTarget();
  const storeA = createPreviewStore(storage, tabA as unknown as Window);
  const storeB = createPreviewStore(storage, tabB as unknown as Window);
  const emitTo = (t: EventTarget) => {
    const e = new Event("storage") as Event & { key: string };
    Object.defineProperty(e, "key", { value: PREVIEW_STORAGE_KEY });
    t.dispatchEvent(e);
  };
  return { storage, storeA, storeB, emitToB: () => emitTo(tabB) };
}

const SENT = "5e55a001-0000-4000-8000-00000000a001";
const EXPORT_SESSION = "5e55a003-0000-4000-8000-00000000a003";

describe("preview workspace", () => {
  it("persists label corrections under a demo-labeled key and shares them across tabs", async () => {
    const { storage, storeA, storeB, emitToB } = twoTabs();
    const a = createPreviewWorkspace(storeA, () => 1_000, 0);
    const b = createPreviewWorkspace(storeB, () => 1_000, 0);
    let notifiedB = 0;
    const unsub = b.subscribe!(() => notifiedB++);

    await a.correctLabel(SENT, "node-01", "Invoice list", undefined);
    const raw = JSON.parse(storage.getItem(PREVIEW_STORAGE_KEY)!);
    expect(raw.demo).toMatch(/sample data only/);
    emitToB();
    expect(notifiedB).toBe(1);
    const seen = await b.getSession(SENT);
    expect(seen.corrections).toEqual([expect.objectContaining({ element_id: "node-01", label: "Invoice list" })]);
    // The agent graph is untouched; corrections are separate records.
    expect(seen.graph?.nodes[0].label).toBe("Invoices");

    const exported = (await b.getGraphExport(SENT)) as { nodes: { label: string }[]; preview_sample: boolean };
    expect(exported.nodes[0].label).toBe("Invoice list");
    expect(exported.preview_sample).toBe(true);

    await b.clearCorrection(SENT, "node-01", "Invoices");
    expect((await a.getSession(SENT)).corrections).toEqual([]);
    unsub();
  });

  it("publishes analysis stages incrementally and skips network when not captured", async () => {
    let now = 50_000;
    const ws = createPreviewWorkspace(createPreviewStore(new MemoryStorage(), null), () => now, 0);
    const before = await ws.getSession(EXPORT_SESSION);
    expect(before.status).toBe("uploaded");
    expect(before.graph).toBeNull();
    expect(before.job).toBeNull();

    await ws.analyze(EXPORT_SESSION);
    now += PREVIEW_STAGE_MS * 1.5;
    const mid = await ws.getSession(EXPORT_SESSION);
    expect(mid.status).toBe("analyzing");
    expect(mid.job?.stages.find((s) => s.name === "network")?.status).toBe("skipped");
    expect(mid.graph).toBeNull();

    now += PREVIEW_STAGE_MS;
    const workflowPublished = await ws.getSession(EXPORT_SESSION);
    expect(workflowPublished.graph?.nodes.length).toBeGreaterThan(0);

    now += PREVIEW_STAGE_MS * 5;
    const done = await ws.getSession(EXPORT_SESSION);
    expect(done.status).toBe("analyzed");
    expect(done.job?.status).toBe("succeeded");
    expect(done.graph?.network_status).toBe("not_captured");
  });

  it("creates projects", async () => {
    const ws = createPreviewWorkspace(createPreviewStore(new MemoryStorage(), null), () => 7, 0);
    const p = await ws.createProject("  Sample CRM  ");
    expect(p.name).toBe("Sample CRM");
    expect((await ws.listProjects()).map((x) => x.name)).toContain("Sample CRM");
    expect(await ws.listSessions(p.id)).toEqual([]);
  });

  it("ignores corrupt or foreign storage contents", () => {
    expect(parseDelta("{not json").projects).toEqual([]);
    expect(parseDelta(JSON.stringify({ version: 9, projects: [{ id: "x", name: "y" }] })).projects).toEqual([]);
  });
});
