import { readFileSync } from "node:fs";
import { describe, expect, it } from "vitest";
import { createApiClient } from "../http";
import { createBackendWorkspace } from "../backend";
import { createRealtime } from "../realtime";

const fixturePath = process.env.RETRACE_LIVE_FIXTURE;
const enabled = Boolean(fixturePath);
const waitFor = async (condition: () => boolean, label: string) => {
  const deadline = Date.now() + 20_000;
  while (!condition()) {
    if (Date.now() > deadline) throw new Error(`Timed out: ${label}`);
    await new Promise((resolve) => setTimeout(resolve, 40));
  }
};

describe.skipIf(!enabled)("real SpacetimeDB subscriptions (synthetic evidence only)", () => {
  it("synchronizes corrections across independent viewer identities and supports restore/re-run/export", async () => {
    const fixture = JSON.parse(readFileSync(fixturePath!, "utf8")) as { api_base_url: string; access_token: string; session_id: string; element_id: string };
    expect(new URL(fixture.api_base_url).hostname).toBe("127.0.0.1");
    const a = createApiClient({ baseUrl: fixture.api_base_url, getToken: () => fixture.access_token });
    const b = createApiClient({ baseUrl: fixture.api_base_url, getToken: () => fixture.access_token });
    const workspace = createBackendWorkspace(a);
    const liveA = createRealtime(a);
    const liveB = createRealtime(b);
    let changesA = 0;
    let changesB = 0;
    const offA = liveA.subscribe(() => changesA++);
    const offB = liveB.subscribe(() => changesB++);
    try {
      await waitFor(() => liveA.status() === "live" && liveB.status() === "live", "both private views subscribed");
      const beforeA = changesA;
      const beforeB = changesB;
      await workspace.correctLabel(fixture.session_id, fixture.element_id, "Two-viewer live correction");
      await waitFor(() => changesA > beforeA && changesB > beforeB, "both subscribers received the correction");
      const peer = await createBackendWorkspace(b).getSession(fixture.session_id);
      expect(peer.corrections.find((c) => c.element_id === fixture.element_id)?.label).toBe("Two-viewer live correction");
      const exported = await workspace.getGraphExport(fixture.session_id) as { nodes: { id: string; label: string }[] };
      expect(exported.nodes.find((n) => n.id === fixture.element_id)?.label).toBe("Two-viewer live correction");
      await workspace.clearCorrection(fixture.session_id, fixture.element_id, "unused");
      expect((await workspace.getSession(fixture.session_id)).corrections).toHaveLength(0);
      const before = await workspace.getSession(fixture.session_id);
      const job = await workspace.analyze(fixture.session_id, undefined, true);
      expect(job.job_id).not.toBe(before.job?.id);
      expect(job.status).toMatch(/queued|running|succeeded/);
    } finally {
      offA(); offB();
      await Promise.all([liveA.dispose(), liveB.dispose(), workspace.dispose?.()]);
    }
  }, 45_000);
});
