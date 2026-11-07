#!/usr/bin/env python3
"""Credit-free local integration smoke: synthetic evidence only, real HTTP and SpacetimeDB."""
import json
import os
import time
import uuid
from pathlib import Path
from urllib.parse import quote

import httpx

ROOT = Path(__file__).resolve().parents[2]
BASE = "http://127.0.0.1:8000"


def main():
    with httpx.Client(base_url=BASE, timeout=15) as client:
        def request(method, path, *, token=None, **kwargs):
            response = client.request(method, path, headers={"Authorization": f"Bearer {token}"} if token else {}, **kwargs)
            assert response.is_success, f"{method} {path}: HTTP {response.status_code}"
            return response.json() if response.content else None

        health = request("GET", "/health")
        assert health["state"]["backend"] == "spacetimedb" and health["state"]["ready"]
        assert health["analysis"]["provider"] == "offline_heuristic", "This smoke must never spend inference credits"
        token = request("POST", "/v1/auth/dev", json={"email": "integration@localhost", "name": "Local integration"})["access_token"]
        project = request("POST", "/v1/projects", token=token, json={"name": "Synthetic integration task"})
        pairing = request("POST", "/v1/pairings", token=token, json={"project_id": project["id"]})
        claim = request("POST", "/v1/pairings/claim", json={"code": pairing["code"], "device_name": "Synthetic recorder"})
        request("POST", f"/v1/pairings/{pairing['pairing_id']}/approve", token=token, json={"claim_id": claim["claim_id"]})
        device = request("POST", f"/v1/pairings/claims/{claim['claim_id']}/poll", json={"claim_secret": claim["claim_secret"]})["device_token"]

        fixture = ROOT / "macos/Tests/RetraceCoreTests/Fixtures/synthetic-session"
        manifest = json.loads((fixture / "manifest.json").read_text())
        manifest.update(id=str(uuid.uuid4()), project_id=project["id"], redaction={"reviewed": True})
        id_map = {item["id"]: str(uuid.uuid4()) for key in ["frames", "interactions", "network"] for item in manifest[key]}
        for key in ["frames", "interactions", "network"]:
            for item in manifest[key]:
                item["id"] = id_map[item["id"]]
                for field in ["before_frame_id", "after_frame_id", "delayed_frame_id"]:
                    if item.get(field):
                        item[field] = id_map[item[field]]
        files = [("files", (frame["filename"], (fixture / "frames" / frame["filename"]).read_bytes(), "image/png")) for frame in manifest["frames"]]
        upload = request("POST", "/v1/sessions", token=device, data={"manifest": json.dumps(manifest)}, files=files)
        assert upload["id"] == manifest["id"]
        duplicate = request("POST", "/v1/sessions", token=device, data={"manifest": json.dumps(manifest)}, files=files)
        assert duplicate["duplicate"]
        sid = manifest["id"]

        def analyzed():
            deadline = time.monotonic() + 20
            while time.monotonic() < deadline:
                session = request("GET", f"/v1/sessions/{sid}", token=token)
                if session["status"] == "analyzed":
                    return session
                assert session["status"] != "failed", "Offline analysis failed"
                time.sleep(.1)
            raise AssertionError("Analysis did not finish within 20 seconds")

        request("POST", f"/v1/sessions/{sid}/analyze", token=token, json={})
        session = analyzed()
        assert session["graph"]["generated_by"]["provider"] == "offline_heuristic"
        assert session["network_status"] == "not_captured"
        element = session["graph"]["nodes"][0]["id"]
        correction_path = f"/v1/sessions/{sid}/corrections/{quote(element, safe='')}"
        request("PUT", correction_path, token=token, json={"label": "Human-reviewed screen"})
        request("POST", f"/v1/sessions/{sid}/analyze", token=token, json={"rerun": True})
        analyzed()
        graph = request("GET", f"/v1/sessions/{sid}/graph?download=1", token=token)
        assert graph["graph_version"] == 2
        assert any(n["id"] == element and n["label"] == "Human-reviewed screen" for n in graph["nodes"])
        request("DELETE", correction_path, token=token)
        assert request("GET", f"/v1/sessions/{sid}/corrections", token=token)["corrections"] == []
        image = client.get(BASE + session["frames"][0]["image_url"], headers={"Authorization": f"Bearer {token}"})
        assert image.status_code == 200 and image.content.startswith(b"\x89PNG")
        unauthorized = client.get(BASE + session["frames"][0]["image_url"])
        assert unauthorized.status_code == 401
        secret_dir = ROOT / "backend/.secrets"
        secret_dir.mkdir(mode=0o700, exist_ok=True)
        target = secret_dir / "integration_fixture.json"
        target.write_text(json.dumps({"api_base_url": BASE, "access_token": token, "project_id": project["id"], "session_id": sid, "element_id": element}))
        os.chmod(target, 0o600)
        export = ROOT / "backend/data/synthetic-integration-graph.json"
        export.write_text(json.dumps(graph, indent=2))
        print(json.dumps({"state": "spacetimedb", "session_id": sid, "stages": len(session["job"]["stages"]), "graph_versions": 2, "nodes": len(graph["nodes"]), "edges": len(graph["edges"]), "pairing_upload_corrections_export": "passed", "model_calls": 0}))


if __name__ == "__main__":
    main()
