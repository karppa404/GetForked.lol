"""Regenerate web/components/landing/spec-sample.data.ts by running the real Retrace exporter
(backend/retrace/export) on two fictional Ledgerline Inventory 3.1 scans. Nothing in the sample is hand-written
except the scan inputs below.

    cd backend && uv run python ../web/scripts/generate-spec-sample.py
"""
import hashlib
import json
from datetime import date
from pathlib import Path

from retrace.analysis.rebuild import rebuild_profile
from retrace.export.bundle import SessionInput, build_bundle
from retrace.models import Manifest

OUT = Path(__file__).resolve().parents[1] / "components/landing/spec-sample.data.ts"
ORIGIN = "http://ledger-srv.local:8080"
HDRS = {"Content-Type": "application/json; charset=utf-8", "Server": "Microsoft-IIS/6.0", "X-Powered-By": "ASP.NET"}

ITEM = {"id": 4211, "sku": "WID-0042", "description": "Hex bolt M8 x 40, zinc", "bin": "B-14", "on_hand": 312, "reorder_point": 150, "unit_cost": 0.38}
ORDER = {"id": 10482, "number": "PO-10482", "supplier_id": 317, "status": "Open", "order_date": "1999-03-12", "total": 1184.5}
SUPPLIER = {"id": 317, "name": "Acme Fasteners", "phone": "555-0142", "terms": "Net 30", "lead_time_days": 9}


def frame(fid, ms):
    return {"id": fid, "timestamp_ms": ms, "filename": f"{fid[:8]}.png", "width": 1024, "height": 768, "sha256": hashlib.sha256(fid.encode()).hexdigest()}


def click(iid, ms, title, before, after, role="AXButton"):
    return {"id": iid, "timestamp_ms": ms, "kind": "double_click" if role == "AXRow" else "click", "x": 0.0, "y": 0.0,
            "accessibility": {"role": role, "title": title}, "before_frame_id": before, "after_frame_id": after}


def net(nid, ms, path, body):
    return {"id": nid, "timestamp_ms": ms, "method": "GET", "url": ORIGIN + path, "status": 200,
            "response_headers": HDRS, "response_body": json.dumps(body)}


def session(sid, started, frames, interactions, network, screens, actions, apis, edges, ambiguities, suggestions):
    manifest = {
        "schema_version": 1, "id": sid, "project_id": "ledgerline",
        "app": {"name": "Ledgerline Inventory 3.1", "bundle_id": "com.ledgerline.inventory3", "pid": 4127},
        "started_at": started, "duration_ms": 60000, "interactions": interactions, "frames": frames,
        "network": network, "network_status": "observed", "redaction": {"reviewed": True},
    }
    m = Manifest.model_validate(manifest)
    nodes = ([{"id": f"screen:{k}", "type": "screen", "label": l, "description": d, "evidence_ids": e} for k, (l, d, e) in enumerate(screens, 1)]
             + [{"id": f"action:{k}", "type": "action", "label": l, "evidence_ids": e} for k, (l, e) in enumerate(actions, 1)]
             + [{"id": f"api:{k}", "type": "api_call", "label": l, "evidence_ids": e} for k, (l, e) in enumerate(apis, 1)])
    for n in nodes:
        if n.get("description") is None:
            n.pop("description", None)
    graph = {"network_status": "observed", "nodes": nodes,
             "edges": [{"source": s, "target": t, "association": a} for s, t, a in edges],
             "ambiguities": [{"message": a} for a in ambiguities],
             "suggestions": [{"label": s, "rationale": ""} for s in suggestions],
             "rebuild_profile": rebuild_profile(m)}
    return SessionInput(sid, graph, m.model_dump(mode="json"))


# Session A: Main Menu -> Inventory -> Item Detail -> Adjust Stock
A = "7c1e4a90-3b5d-4f2e-9a61-0d8e2c4b7f13"
fa = ["0f4b8e21-7c3a-4d59-b1e6-2a9d5c7f0384", "5d2c91a7-e04b-4f63-8a1d-7b3e6c0f9152", "b84e0d3f-29c6-4a17-95e2-c1f7a3d60b48", "3a7f5c09-d1b2-4e86-a3c4-8f0b2e9d7165"]
ia = ["a2d4f6b8-1c3e-4a5b-9d7f-0e2c4a6b8d10", "c4e6a8b0-3d5f-4b7c-8e9a-1f3d5b7c9e21", "e6a8c0d2-5f7b-4d9e-a0b1-2a4c6e8f0a32"]
na = ["8d1f3b27-4c6e-4a90-b5d8-0e2f7a9c1364", "4b6a0e92-d3f1-47c8-a2e5-9f1c7b3d0856"]
sa = session(
    A, "2026-11-07T15:02:00Z",
    [frame(f, k * 4000) for k, f in enumerate(fa)],
    [click(ia[0], 1200, "Inventory", fa[0], fa[1]), click(ia[1], 5100, "WID-0042", fa[1], fa[2], "AXRow"), click(ia[2], 9300, "Adjust Stock…", fa[2], fa[3])],
    [net(na[0], 1400, "/api/items?page=1", [ITEM]), net(na[1], 5300, "/api/items/4211", ITEM)],
    [("Main Menu", "Launcher window with large toolbar buttons for Inventory, Orders, Suppliers and Reports, and a status bar showing the connected database and signed-in clerk. Reports was not opened.", [fa[0]]),
     ("Inventory", "Sortable grid of stock items: SKU, description, bin, on hand and reorder point, with rows under the reorder point shaded. Toolbar has Find, Filter and Print; Print was not tested.", [fa[1]]),
     ("Item Detail", "Single-item form for WID-0042 with read-only stock fields, cost history and an Adjust Stock… button. Edit mode was not entered.", [fa[2]]),
     ("Adjust Stock", "Modal dialog with a quantity delta, reason code dropdown and OK/Cancel. Closed with Cancel; the adjustment itself was not submitted.", [fa[3]])],
    [("Open Inventory", [ia[0], fa[0], fa[1]]), ("Open item WID-0042", [ia[1], fa[1], fa[2]]), ("Click Adjust Stock…", [ia[2], fa[2], fa[3]])],
    [("GET /api/items", [na[0]]), ("GET /api/items/{itemId}", [na[1]])],
    [("screen:1", "action:1", "observed"), ("action:1", "screen:2", "observed"), ("screen:2", "action:2", "observed"),
     ("action:2", "screen:3", "observed"), ("screen:3", "action:3", "observed"), ("action:3", "screen:4", "observed"),
     ("action:1", "api:1", "candidate"), ("action:2", "api:2", "candidate")],
    ["Adjust Stock was opened but not submitted because saving writes stock levels"],
    ["Type-ahead search in the Inventory grid"],
)

# Session B: Orders -> Order PO-10482 -> Supplier Card
B = "9b2f07d3-61ac-4e88-b0f4-5a7d13c9e260"
fb = ["c6e2a8d4-f913-4b07-8d5a-1e4c9b7f2036", "71b9d3e5-08a4-4c2f-b6e1-9d3a5f7c0824", "2e8c4f61-a7d9-4b35-9c02-6f1e8b3d4a97"]
ib = ["f1a3c5e7-9b0d-4f2a-8c4e-6a8b0d2f4a63", "b3c5e7a9-0d2f-4a4c-9e6a-8c0d2f4b6c74"]
nb = ["f2c7e4a1-6b09-4d3e-8f15-a0d9c2e7b483", "9e3d5b70-12af-4c68-b7e4-3c8f0a6d2915", "6a0f2d8c-b5e3-4917-a4c6-d2e8f1b07539"]
sb = session(
    B, "2026-11-07T15:09:00Z",
    [frame(f, k * 4000) for k, f in enumerate(fb)],
    [click(ib[0], 1700, "PO-10482", fb[0], fb[1], "AXRow"), click(ib[1], 5600, "Acme Fasteners", fb[1], fb[2], "AXLink")],
    [net(nb[0], 300, "/api/orders?status=open", [ORDER]), net(nb[1], 1900, "/api/orders/10482", ORDER | {"lines": [{"sku": "WID-0042", "qty": 2500, "unit_cost": 0.38}]}),
     net(nb[2], 5800, "/api/suppliers/317", SUPPLIER)],
    [("Orders", "Purchase order list with number, supplier, status, order date and total, filtered to Open by default. New PO and Receive buttons were visible but not pressed.", [fb[0]]),
     ("Order PO-10482", "Order header (supplier, terms, dates) above a line-item grid with SKU, quantity and unit cost, plus a running total. Receive and Void were not tested.", [fb[1]]),
     ("Supplier Card", None, [fb[2]])],
    [("Open order PO-10482", [ib[0], fb[0], fb[1]]), ("Open supplier Acme Fasteners", [ib[1], fb[1], fb[2]])],
    [("GET /api/orders", [nb[0]]), ("GET /api/orders/{orderId}", [nb[1]]), ("GET /api/suppliers/{supplierId}", [nb[2]])],
    [("screen:1", "action:1", "observed"), ("action:1", "screen:2", "observed"), ("screen:2", "action:2", "observed"),
     ("action:2", "screen:3", "observed"), ("action:1", "api:2", "candidate"), ("action:2", "api:3", "candidate")],
    ["Reports and the Suppliers list were not explored in this scan"],
    [],
)

files = build_bundle("Ledgerline Inventory 3.1", [sa, sb], lambda s, f: (b"PNG", ".png"), today=date(2026, 11, 7))
root = next(iter(files)).split("/")[0]
# Only the files the landing page renders; the rest of the bundle is listed by path.
SHOWN = {"AGENTS.md", "contracts/arazzo.json", "contracts/openapi.json", "reference/pages.md", "reference/rebuild-profile.json",
         "specs/001-ledgerline-inventory-3-1-clone/spec.md"}
lines = [
    "// Generated by web/scripts/generate-spec-sample.py from the real exporter. Do not edit by hand.",
    f"export const SAMPLE_ROOT = {json.dumps(root)};",
    "export const SAMPLE_FILES: Record<string, string> = {",
]
for path, data in files.items():
    if path.removeprefix(root + "/") in SHOWN:
        lines.append(f"  {json.dumps(path.removeprefix(root + '/'))}: {json.dumps(data.decode(), ensure_ascii=False)},")
lines += ["};", "export const SAMPLE_PATHS: string[] = " + json.dumps([p.removeprefix(root + "/") for p in files]) + ";", ""]
OUT.write_text("\n".join(lines))
print(f"wrote {OUT}")
