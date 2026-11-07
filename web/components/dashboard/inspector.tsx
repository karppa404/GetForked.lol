"use client";

import { useState } from "react";
import { formatTimestamp } from "@/lib/dashboard/graph";
import type { EvidenceItem, Frame } from "@/lib/dashboard/types";
import { FrameImage, describeEvidence } from "./evidence-media";
import { LabelEditor } from "./label-editor";
import { elementEvidence, elementLabel, typeLabel, type SessionModel, type Selection } from "./session-model";

interface Props {
  model: SessionModel;
  selection: Selection;
  onSelect: (s: Selection) => void;
  onRename: (id: string, label: string) => Promise<void>;
  onRestore: (id: string) => Promise<void>;
}

export function Inspector({ model, selection, onSelect, onRename, onRestore }: Props) {
  return (
    <aside className="rd-inspector" aria-label="Inspector" aria-live="polite">
      {selection?.kind === "element" && model.elements.has(selection.id) ? (
        <ElementDetail key={selection.id} id={selection.id} model={model} onSelect={onSelect} onRename={onRename} onRestore={onRestore} />
      ) : selection?.kind === "evidence" && model.evidenceById.has(selection.id) ? (
        <EvidenceDetail item={model.evidenceById.get(selection.id)!} model={model} onSelect={onSelect} />
      ) : (
        <Overview model={model} onSelect={onSelect} />
      )}
    </aside>
  );
}

function Overview({ model, onSelect }: { model: SessionModel; onSelect: (s: Selection) => void }) {
  const { graph, session } = model;
  const open = graph?.ambiguities ?? [];
  return (
    <div className="rd-insp">
      <p className="rd-insp-eyebrow">SESSION</p>
      <h2 className="rd-insp-title">What was observed</h2>
      <dl className="rd-stats">
        <div><dt>Interactions</dt><dd>{session.interactions.length}</dd></div>
        <div><dt>Screenshots</dt><dd>{session.frames.length}</dd></div>
        <div><dt>Requests</dt><dd>{session.network_status === "not_captured" ? "—" : session.network.length}</dd></div>
        <div><dt>Corrections</dt><dd>{model.edited.size}</dd></div>
      </dl>
      {graph ? (
        <p className="rd-insp-hint">Select a node or connection to see the evidence behind it, or pick an item in the timeline to see what cites it.</p>
      ) : (
        <p className="rd-insp-hint">Evidence is available now. Graph elements appear after analysis.</p>
      )}
      {open.length > 0 && (
        <section className="rd-insp-section">
          <h3>Open questions <span className="rd-count">{open.length}</span></h3>
          <ul className="rd-questions">
            {open.map((a, i) => (
              <li key={i}>
                <p>{a.message}</p>
                {a.element_id && model.elements.has(a.element_id) && (
                  <button type="button" className="rd-link-btn" onClick={() => onSelect({ kind: "element", id: a.element_id! })}>
                    {elementLabel(model.elements.get(a.element_id)!)} →
                  </button>
                )}
              </li>
            ))}
          </ul>
        </section>
      )}
    </div>
  );
}

function ElementDetail({ id, model, onSelect, onRename, onRestore }: { id: string } & Omit<Props, "selection">) {
  const el = model.elements.get(id)!;
  const [editing, setEditing] = useState(false);
  const [restoring, setRestoring] = useState(false);
  const [restoreError, setRestoreError] = useState<string | null>(null);
  const label = elementLabel(el);
  const agentLabel = model.agentLabel.get(id) ?? label;
  const correction = model.edited.get(id);
  const evidence = elementEvidence(model, id).map((e) => model.evidenceById.get(e)).filter((x): x is EvidenceItem => Boolean(x));
  const missing = elementEvidence(model, id).length - evidence.length;
  const questions = model.ambiguities.get(id) ?? [];
  const graph = model.graph!;
  const nodeLabel = (nid: string) => graph.nodes.find((n) => n.id === nid)?.label ?? nid;

  const incoming = el.kind === "node" ? graph.edges.filter((e) => e.target === id) : [];
  const outgoing = el.kind === "node" ? graph.edges.filter((e) => e.source === id) : [];

  return (
    <div className="rd-insp">
      <div className="rd-insp-top">
        <p className="rd-insp-eyebrow">{el.kind === "node" ? typeLabel(el.node.type).toUpperCase() : "CONNECTION"}</p>
        <button type="button" className="rd-icon-btn" onClick={() => onSelect(null)} aria-label="Close inspector">×</button>
      </div>
      {editing ? (
        <LabelEditor initial={label} label="Label" onCancel={() => setEditing(false)} onSave={async (v) => { await onRename(id, v); setEditing(false); }} />
      ) : (
        <div className="rd-insp-label">
          <h2 className="rd-insp-title">{label || <em>Unlabeled</em>}</h2>
          <button type="button" className="rd-btn rd-btn--ghost rd-btn--small" onClick={() => setEditing(true)}>Rename</button>
        </div>
      )}
      {correction && !editing && (
        <div className="rd-correction">
          <span className="rd-edited-tag">Edited</span>
          <span>Agent label: <q>{agentLabel}</q>{correction.author ? ` · by ${correction.author}` : ""}</span>
          <button type="button" className="rd-link-btn" disabled={restoring} onClick={async () => {
            setRestoring(true);
            setRestoreError(null);
            try {
              await onRestore(id);
            } catch (e) {
              setRestoreError(e instanceof Error ? e.message : "Couldn’t restore the agent label.");
            } finally {
              setRestoring(false);
            }
          }}>{restoring ? "Restoring…" : "Restore agent label"}</button>
        </div>
      )}
      {restoreError && <p className="rd-form-error" role="alert">{restoreError}</p>}

      {el.kind === "edge" && (
        <div className={`rd-assoc rd-assoc--${el.edge.association}`}>
          <strong>{el.edge.association === "observed" ? "Observed" : "Candidate"}</strong>
          <span>{el.edge.association === "observed" ? "Seen directly in the recorded evidence." : "Inferred from timing or context — not directly observed. Verify before relying on it."}</span>
          <p className="rd-assoc-path">
            <button type="button" className="rd-link-btn" onClick={() => onSelect({ kind: "element", id: el.edge.source })}>{nodeLabel(el.edge.source)}</button>
            <span aria-hidden="true"> → </span>
            <button type="button" className="rd-link-btn" onClick={() => onSelect({ kind: "element", id: el.edge.target })}>{nodeLabel(el.edge.target)}</button>
          </p>
        </div>
      )}

      {questions.length > 0 && (
        <section className="rd-insp-section">
          <h3>Open question</h3>
          {questions.map((q, i) => <p key={i} className="rd-question">{q.message}</p>)}
        </section>
      )}

      <section className="rd-insp-section">
        <h3>Supporting evidence <span className="rd-count">{evidence.length}</span></h3>
        {evidence.length === 0 && <p className="rd-muted">No evidence cited.{el.kind === "edge" && el.edge.association === "candidate" ? " Candidate connections can be purely inferred." : ""}</p>}
        {missing > 0 && <p className="rd-form-error">{missing} cited evidence {missing === 1 ? "item is" : "items are"} missing from this session.</p>}
        <ul className="rd-evidence-list">
          {evidence.map((item) => (
            <li key={item.id}>
              <EvidenceCard item={item} sessionId={model.session.id} onOpen={() => onSelect({ kind: "evidence", id: item.id })} />
            </li>
          ))}
        </ul>
      </section>

      {(incoming.length > 0 || outgoing.length > 0) && (
        <section className="rd-insp-section">
          <h3>Connections</h3>
          <ul className="rd-connections">
            {incoming.map((e) => (
              <li key={e.id}><button type="button" className="rd-link-btn" onClick={() => onSelect({ kind: "element", id: e.id })}>← {nodeLabel(e.source)} <span className="rd-muted">· {e.label || "connection"}{e.association === "candidate" ? " · candidate" : ""}</span></button></li>
            ))}
            {outgoing.map((e) => (
              <li key={e.id}><button type="button" className="rd-link-btn" onClick={() => onSelect({ kind: "element", id: e.id })}>→ {nodeLabel(e.target)} <span className="rd-muted">· {e.label || "connection"}{e.association === "candidate" ? " · candidate" : ""}</span></button></li>
            ))}
          </ul>
        </section>
      )}
    </div>
  );
}

function EvidenceCard({ item, sessionId, onOpen }: { item: EvidenceItem; sessionId: string; onOpen: () => void }) {
  const d = describeEvidence(item);
  return (
    <button type="button" className="rd-ev-card" onClick={onOpen}>
      {item.kind === "frame" && <span className="rd-ev-media"><FrameImage sessionId={sessionId} frame={item.data} /></span>}
      <span className="rd-ev-line">
        <span className="rd-tl-time">{formatTimestamp(item.timestamp_ms)}</span>
        <span aria-hidden="true" className="rd-tl-symbol">{d.symbol}</span>
        <span className="rd-ev-text"><b>{d.title}</b><span>{d.detail}</span></span>
      </span>
    </button>
  );
}

function EvidenceDetail({ item, model, onSelect }: { item: EvidenceItem; model: SessionModel; onSelect: (s: Selection) => void }) {
  const d = describeEvidence(item);
  const citedBy = model.citations.get(item.id) ?? [];
  const relatedFrames: { caption: string; frame: Frame }[] = [];
  if (item.kind === "interaction") {
    for (const [caption, fid] of [["Before", item.data.before_frame_id], ["After", item.data.after_frame_id]] as const) {
      const f = fid ? model.evidenceById.get(fid) : undefined;
      if (f?.kind === "frame") relatedFrames.push({ caption, frame: f.data });
    }
  }
  return (
    <div className="rd-insp">
      <div className="rd-insp-top">
        <p className="rd-insp-eyebrow">{item.kind === "frame" ? "SCREENSHOT" : item.kind === "interaction" ? "INTERACTION" : "NETWORK REQUEST"} · {formatTimestamp(item.timestamp_ms)}</p>
        <button type="button" className="rd-icon-btn" onClick={() => onSelect(null)} aria-label="Close inspector">×</button>
      </div>
      <h2 className="rd-insp-title rd-insp-title--evidence">{d.title}</h2>
      <p className="rd-muted">{d.detail}</p>
      {item.kind === "frame" && <div className="rd-insp-media"><FrameImage sessionId={model.session.id} frame={item.data} /></div>}
      {relatedFrames.length > 0 && (
        <div className="rd-before-after">
          {relatedFrames.map((r) => (
            <figure key={r.caption}>
              <FrameImage sessionId={model.session.id} frame={r.frame} />
              <figcaption>{r.caption}</figcaption>
            </figure>
          ))}
        </div>
      )}
      {item.kind === "network" && (
        <dl className="rd-kv">
          <div><dt>Method</dt><dd>{item.data.method}</dd></div>
          <div><dt>URL</dt><dd className="rd-mono">{item.data.url}</dd></div>
          <div><dt>Status</dt><dd>{item.data.status ?? "—"}</dd></div>
        </dl>
      )}
      <p className="rd-fine rd-mono">id {item.id}</p>
      <section className="rd-insp-section">
        <h3>Cited by <span className="rd-count">{citedBy.length}</span></h3>
        {citedBy.length === 0 ? (
          <p className="rd-muted">{model.graph ? "No graph element cites this evidence." : "Run analysis to link evidence to the graph."}</p>
        ) : (
          <ul className="rd-connections">
            {citedBy.map((id) => {
              const el = model.elements.get(id);
              if (!el) return null;
              return (
                <li key={id}>
                  <button type="button" className="rd-link-btn" onClick={() => onSelect({ kind: "element", id })}>
                    {elementLabel(el) || "Unlabeled"} <span className="rd-muted">· {el.kind === "node" ? typeLabel(el.node.type) : "connection"}</span>
                  </button>
                </li>
              );
            })}
          </ul>
        )}
      </section>
    </div>
  );
}
