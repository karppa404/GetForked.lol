import pytest

from retrace.graph import EvidenceIndex, GraphValidationError, apply_corrections, assert_publishable, normalize_graph
from retrace.state.base import CorrectionRec

F1, F2, I1, N1 = "f-1", "f-2", "i-1", "n-1"


def idx(capture="captured"):
    return EvidenceIndex({F1: "frame", F2: "frame", I1: "interaction", N1: "network"}, {F1: 0, F2: 2000, I1: 1000, N1: 1200}, capture)


def draft(**extra):
    d = {
        "nodes": [
            {"id": "s1", "type": "screen", "label": "Orders", "evidence_ids": [F1]},
            {"id": "s2", "type": "screen", "label": "Saved", "evidence_ids": [F2]},
            {"id": "a1", "type": "action", "label": "Click Save", "evidence_ids": [I1, F1]},
            {"id": "n1", "type": "api_call", "label": "POST /orders", "evidence_ids": [N1]},
        ],
        "edges": [
            {"source": "s1", "target": "a1", "evidence_ids": [I1], "association": "observed"},
            {"source": "a1", "target": "s2", "evidence_ids": [I1], "association": "observed"},
            {"source": "a1", "target": "n1", "evidence_ids": [I1, N1], "association": "observed"},
        ],
        "ambiguities": ["Two save buttons look alike"],
    }
    d.update(extra)
    return d


def test_valid_graph_normalized_with_stable_ids():
    r = normalize_graph(draft(), idx(), "sess")
    g = r.graph
    ids = {n["id"] for n in g["nodes"]}
    assert ids == {f"screen:{F1}", f"screen:{F2}", f"action:{I1}", f"api_call:{N1}"}
    assert g["network_status"] == "observed"
    api_edge = next(e for e in g["edges"] if e["target"] == f"api_call:{N1}")
    assert api_edge["association"] == "candidate" and api_edge["basis"] == "timing"
    assert any("downgraded" in p for p in r.problems)
    workflow_edge = next(e for e in g["edges"] if e["target"] == f"action:{I1}")
    assert workflow_edge["association"] == "observed"
    action = next(n for n in g["nodes"] if n["type"] == "action")
    assert action["network_status"] == "observed"
    assert_publishable(g, idx())
    # rerun with different model-chosen ids gives the same element ids
    d2 = draft()
    for n in d2["nodes"]:
        n["id"] = "x-" + n["id"]
    for e in d2["edges"]:
        e["source"], e["target"] = "x-" + e["source"], "x-" + e["target"]
    assert {n["id"] for n in normalize_graph(d2, idx(), "sess").graph["nodes"]} == ids


def test_invalid_evidence_and_references_dropped():
    d = draft()
    d["nodes"].append({"id": "ghost", "type": "screen", "label": "Ghost", "evidence_ids": ["made-up"]})
    d["nodes"].append({"id": "wrongkind", "type": "api_call", "label": "x", "evidence_ids": [F1]})
    d["edges"].append({"source": "s1", "target": "ghost", "evidence_ids": [F1]})
    d["edges"].append({"source": "s1", "target": "s2", "evidence_ids": ["made-up"]})
    d["edges"].append({"source": "s1", "target": "s1", "evidence_ids": [F1]})
    d["edges"].append({"source": "s2", "target": "s1", "evidence_ids": [F2], "association": "observed"})
    r = normalize_graph(d, idx(), "sess")
    g = r.graph
    assert len(g["nodes"]) == 4
    assert all(all(e in idx().kinds for e in n["evidence_ids"]) for n in g["nodes"] + g["edges"])
    back = next(e for e in g["edges"] if e["source"] == f"screen:{F2}")
    assert back["association"] == "candidate"  # no interaction evidence
    assert len(r.problems) >= 5
    assert_publishable(g, idx())


def test_not_captured_vs_none_observed():
    g = normalize_graph(draft(), idx("not_captured"), "s").graph
    assert g["network_status"] == "not_captured"
    assert not any(n["type"] == "api_call" for n in g["nodes"])
    assert next(n for n in g["nodes"] if n["type"] == "action")["network_status"] == "not_captured"
    assert_publishable(g, idx("not_captured"))

    d = draft()
    d["nodes"] = [n for n in d["nodes"] if n["type"] != "api_call"]
    g = normalize_graph(d, idx("captured"), "s").graph
    assert g["network_status"] == "none_observed"
    assert next(n for n in g["nodes"] if n["type"] == "action")["network_status"] == "none_observed"


def test_suggestions_never_observed():
    d = draft(suggestions=[{"label": "Replace polling with webhooks", "related_element_ids": ["n1"]}])
    d["nodes"].append({"id": "p1", "type": "suggestion", "label": "Add bulk import", "evidence_ids": []})
    g = normalize_graph(d, idx(), "s").graph
    assert all(n["type"] != "suggestion" for n in g["nodes"])
    labels = [s["label"] for s in g["suggestions"]]
    assert labels == ["Replace polling with webhooks", "Add bulk import"]
    assert all(s["kind"] == "suggestion" and "association" not in s for s in g["suggestions"])
    assert g["suggestions"][0]["related_element_ids"] == [f"api_call:{N1}"]


def test_assert_publishable_rejects_violations():
    g = normalize_graph(draft(), idx(), "s").graph
    bad = {**g, "edges": [dict(e, association="observed") for e in g["edges"]]}
    with pytest.raises(GraphValidationError):
        assert_publishable(bad, idx())
    bad = {**g, "nodes": g["nodes"] + [{"id": "screen:zzz", "type": "screen", "label": "x", "evidence_ids": ["zzz"]}]}
    with pytest.raises(GraphValidationError):
        assert_publishable(bad, idx())
    with pytest.raises(GraphValidationError):
        assert_publishable({**g, "network_status": "none_observed"}, idx())
    with pytest.raises(GraphValidationError):
        assert_publishable(g, idx("not_captured"))


def test_labels_cleaned_and_caps():
    d = draft()
    d["nodes"][0]["label"] = "Line\x00one\n\n" + "x" * 1000
    d["nodes"] += [{"id": f"s{k}", "type": "screen", "label": "", "evidence_ids": [F1]} for k in range(500)]
    g = normalize_graph(d, idx(), "s").graph
    n = next(n for n in g["nodes"] if n["id"] == f"screen:{F1}")
    assert "\x00" not in n["label"] and len(n["label"]) <= 200
    assert len(g["nodes"]) == 4  # duplicates merged by evidence


def test_corrections_overlay():
    g = normalize_graph(draft(), idx(), "s").graph
    c = [CorrectionRec("s:x", "s", f"screen:{F1}", "Order list", "u", "t"), CorrectionRec("s:y", "s", "screen:gone", "Old", "u", "t")]
    out = apply_corrections(g, c)
    node = next(n for n in out["nodes"] if n["id"] == f"screen:{F1}")
    assert node["label"] == "Order list" and node["agent_label"] == "Orders" and node["corrected"]
    assert [x["applied"] for x in out["corrections"]] == [True, False]
