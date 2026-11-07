"use client";

import { useMemo, useRef, useState, type KeyboardEvent } from "react";
import { layeredLayout, networkView, workflowView, type GraphView } from "@/lib/dashboard/graph";
import { GraphCanvas } from "./graph-canvas";
import { LabelEditor } from "./label-editor";
import { elementEvidence, typeLabel, type SessionModel, type Selection } from "./session-model";
import { EmptyState, Spinner } from "./ui";

type Tab = "workflow" | "network";
type Mode = "canvas" | "outline";

interface Props {
  model: SessionModel;
  selection: Selection;
  onSelect: (s: Selection) => void;
  onRename: (id: string, label: string) => Promise<void>;
  analysisRunning: boolean;
  networkStageDone: boolean;
  onAnalyze: () => void;
}

export function GraphPanel({ model, selection, onSelect, onRename, analysisRunning, networkStageDone, onAnalyze }: Props) {
  const [tab, setTab] = useState<Tab>("workflow");
  const [mode, setMode] = useState<Mode>("canvas");
  const tabRefs = useRef<Record<Tab, HTMLButtonElement | null>>({ workflow: null, network: null });
  const { graph, session } = model;

  const views = useMemo(() => (graph ? { workflow: workflowView(graph), network: networkView(graph) } : null), [graph]);

  const highlightedIds = useMemo(() => {
    if (selection?.kind === "evidence") return new Set(model.citations.get(selection.id) ?? []);
    return new Set<string>();
  }, [selection, model.citations]);
  const editedIds = useMemo(() => new Set(model.edited.keys()), [model.edited]);
  const ambiguousIds = useMemo(() => new Set([...model.ambiguities.keys()].filter(Boolean)), [model.ambiguities]);

  const onTabKey = (e: KeyboardEvent) => {
    if (e.key !== "ArrowRight" && e.key !== "ArrowLeft") return;
    const next: Tab = tab === "workflow" ? "network" : "workflow";
    setTab(next);
    tabRefs.current[next]?.focus();
  };

  const netCount = views?.network.nodes.filter((n) => !views.network.contextNodeIds.has(n.id)).length ?? 0;
  const tabs: { id: Tab; label: string; count: string }[] = [
    { id: "workflow", label: "Workflow", count: views ? String(views.workflow.nodes.length) : "" },
    { id: "network", label: "API & network", count: session.network_status === "not_captured" ? "Not captured" : session.network_status === "none_observed" ? "None" : views ? String(netCount) : "" },
  ];

  const view = views?.[tab];
  let body: React.ReactNode;
  if (!graph || !view) {
    body = analysisRunning ? (
      <EmptyState symbol="⌁" title="Mapping the workflow…"><p>The graph appears here as analysis stages publish. You can review evidence in the meantime.</p></EmptyState>
    ) : (
      <EmptyState symbol="⌁" title="Not analyzed yet" action={<button type="button" className="rd-btn rd-btn--primary" onClick={onAnalyze}>Run analysis</button>}>
        <p>Analysis turns this session’s screenshots, interactions{session.network_status === "observed" ? " and requests" : ""} into an evidence-backed graph.</p>
      </EmptyState>
    );
  } else if (tab === "network" && session.network_status === "not_captured") {
    body = (
      <EmptyState symbol="⊘" title="Network not captured">
        <p>This session was recorded without network capture, so Retrace can’t show which APIs the workflow depends on. The workflow is still grounded in screenshots and interactions.</p>
        <p className="rd-fine">To map APIs, record the task again with network capture enabled in the recorder.</p>
      </EmptyState>
    );
  } else if (tab === "network" && session.network_status === "none_observed") {
    body = (
      <EmptyState symbol="∅" title="No network activity observed">
        <p>Network capture was on, but the app made no requests during this task. It may work from local data, a cache, or sync later in the background.</p>
      </EmptyState>
    );
  } else if (tab === "network" && view.nodes.length === 0) {
    body = analysisRunning && !networkStageDone ? (
      <EmptyState symbol="⇄" title="Tracing network…"><p>API dependencies appear once the network stage publishes.</p></EmptyState>
    ) : (
      <EmptyState symbol="⇄" title="No API dependencies in the graph"><p>Requests were captured, but none were linked to workflow steps.</p></EmptyState>
    );
  } else if (view.nodes.length === 0) {
    body = <EmptyState symbol="⌁" title="Empty workflow"><p>The published graph has no workflow steps.</p></EmptyState>;
  } else if (mode === "canvas") {
    body = (
      <GraphCanvas
        view={view}
        selection={selection}
        highlightedIds={highlightedIds}
        editedIds={editedIds}
        ambiguousIds={ambiguousIds}
        onSelect={onSelect}
        onRename={onRename}
        ariaLabel={`${tab === "workflow" ? "Workflow" : "API and network"} graph canvas. Use the outline view for a keyboard-friendly list.`}
      />
    );
  } else {
    body = <GraphOutline view={view} model={model} selection={selection} highlightedIds={highlightedIds} onSelect={onSelect} onRename={onRename} />;
  }

  return (
    <section className="rd-graph-panel" aria-label="Session graph">
      <div className="rd-graph-toolbar">
        <div role="tablist" aria-label="Graph views" className="rd-tabs" onKeyDown={onTabKey}>
          {tabs.map((t) => (
            <button
              key={t.id}
              ref={(el) => { tabRefs.current[t.id] = el; }}
              role="tab"
              id={`rd-tab-${t.id}`}
              aria-selected={tab === t.id}
              aria-controls="rd-graph-tabpanel"
              tabIndex={tab === t.id ? 0 : -1}
              className="rd-tab"
              onClick={() => setTab(t.id)}
            >
              {t.label}
              {t.count && <span className="rd-tab-count">{t.count}</span>}
            </button>
          ))}
        </div>
        <div className="rd-graph-tools">
          {analysisRunning && graph && <span className="rd-muted rd-updating"><Spinner label="Updating" /> Updating as stages publish</span>}
          <div className="rd-segmented" role="group" aria-label="Graph display">
            <button type="button" aria-pressed={mode === "canvas"} onClick={() => setMode("canvas")}>Canvas</button>
            <button type="button" aria-pressed={mode === "outline"} onClick={() => setMode("outline")}>Outline</button>
          </div>
        </div>
      </div>
      <div id="rd-graph-tabpanel" role="tabpanel" aria-labelledby={`rd-tab-${tab}`} className="rd-graph-body">
        {body}
      </div>
      {graph && view && view.nodes.length > 0 && (
        <div className="rd-legend" aria-label="Legend">
          <span><i className="rd-legend-line" /> Observed</span>
          <span><i className="rd-legend-line rd-legend-line--candidate" /> Candidate — inferred, not directly observed</span>
          <span><b className="rd-edited-tag">Edited</b> Human correction</span>
          {mode === "canvas" && <span className="rd-legend-hint">Double-click a node to rename · drag to rearrange (layout isn’t saved)</span>}
        </div>
      )}
    </section>
  );
}

function GraphOutline({ view, model, selection, highlightedIds, onSelect, onRename }: { view: GraphView; model: SessionModel; selection: Selection; highlightedIds: Set<string>; onSelect: (s: Selection) => void; onRename: (id: string, label: string) => Promise<void> }) {
  const [editing, setEditing] = useState<string | null>(null);
  const ordered = useMemo(() => {
    const pos = layeredLayout(view.nodes, view.edges);
    return [...view.nodes].sort((a, b) => pos[a.id].x - pos[b.id].x || pos[a.id].y - pos[b.id].y);
  }, [view]);
  const byId = new Map(view.nodes.map((n) => [n.id, n]));
  const selectedId = selection?.kind === "element" ? selection.id : null;

  const row = (id: string, label: string, kindLabel: string, sources: number, extra?: React.ReactNode) => (
    <div className={`rd-outline-row${selectedId === id ? " is-selected" : ""}${highlightedIds.has(id) ? " is-highlighted" : ""}`}>
      {editing === id ? (
        <LabelEditor initial={label} label={`Rename ${kindLabel}`} onCancel={() => setEditing(null)} onSave={async (v) => { await onRename(id, v); setEditing(null); }} />
      ) : (
        <>
          <button type="button" className="rd-outline-select" aria-pressed={selectedId === id} onClick={() => onSelect({ kind: "element", id })}>
            <span className="rd-outline-kind">{kindLabel}</span>
            <span className="rd-outline-label">{label || <em>Unlabeled</em>}</span>
            {extra}
            <span className="rd-outline-sources">{sources} {sources === 1 ? "source" : "sources"}</span>
            {model.edited.has(id) && <span className="rd-edited-tag">Edited</span>}
          </button>
          <button type="button" className="rd-btn rd-btn--ghost rd-btn--small" onClick={() => setEditing(id)} aria-label={`Rename ${label}`}>Rename</button>
        </>
      )}
    </div>
  );

  return (
    <ol className="rd-outline" aria-label="Graph outline">
      {ordered.map((n, i) => (
        <li key={n.id}>
          <span className="rd-outline-index" aria-hidden="true">{String(i + 1).padStart(2, "0")}</span>
          <div className="rd-outline-item">
            {row(n.id, n.label, typeLabel(n.type) + (view.contextNodeIds.has(n.id) ? " (context)" : ""), elementEvidence(model, n.id).length)}
            {view.edges.filter((e) => e.source === n.id).map((e) => (
              <div key={e.id} className="rd-outline-edge">
                {row(e.id, e.label, e.association === "candidate" ? "Candidate →" : "Observed →", e.evidence_ids.length, <span className="rd-outline-target">to {byId.get(e.target)?.label ?? e.target}</span>)}
              </div>
            ))}
          </div>
        </li>
      ))}
    </ol>
  );
}
