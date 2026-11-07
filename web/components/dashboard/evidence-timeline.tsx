"use client";

import { useEffect, useMemo, useRef, useState } from "react";
import { formatTimestamp } from "@/lib/dashboard/graph";
import type { EvidenceItem } from "@/lib/dashboard/types";
import { describeEvidence } from "./evidence-media";
import { elementEvidence, type SessionModel, type Selection } from "./session-model";

type Filter = "all" | "interaction" | "frame" | "network";

export function EvidenceTimeline({ model, selection, onSelect }: { model: SessionModel; selection: Selection; onSelect: (s: Selection) => void }) {
  const [filter, setFilter] = useState<Filter>("all");
  const listRef = useRef<HTMLOListElement>(null);
  const { session, evidence } = model;

  const highlighted = useMemo(() => {
    if (selection?.kind === "element") return new Set(elementEvidence(model, selection.id));
    if (selection?.kind === "evidence") return new Set([selection.id]);
    return new Set<string>();
  }, [model, selection]);

  const counts = useMemo(() => ({
    all: evidence.length,
    interaction: session.interactions.length,
    frame: session.frames.length,
    network: session.network.length,
  }), [evidence.length, session]);

  const visible = filter === "all" ? evidence : evidence.filter((e) => e.kind === filter);

  useEffect(() => {
    if (!highlighted.size) return;
    const first = listRef.current?.querySelector<HTMLElement>("[data-highlighted='true']");
    first?.scrollIntoView({ block: "nearest", behavior: window.matchMedia("(prefers-reduced-motion: reduce)").matches ? "auto" : "smooth" });
  }, [highlighted]);

  const networkLabel = session.network_status === "not_captured" ? "Not captured" : session.network_status === "none_observed" ? "None observed" : null;

  const chips: { id: Filter; label: string }[] = [
    { id: "all", label: "All" },
    { id: "interaction", label: "Actions" },
    { id: "frame", label: "Screens" },
    { id: "network", label: "Network" },
  ];

  return (
    <section className="rd-timeline" aria-labelledby="rd-timeline-title">
      <div className="rd-panel-head">
        <h2 id="rd-timeline-title">Evidence</h2>
        <span className="rd-count">{evidence.length}</span>
      </div>
      <div className="rd-chips" role="group" aria-label="Filter evidence">
        {chips.map((c) => (
          <button key={c.id} type="button" className="rd-chip" aria-pressed={filter === c.id} onClick={() => setFilter(c.id)} title={c.id === "network" && networkLabel ? `Network: ${networkLabel}` : undefined}>
            {c.label} <span>{c.id === "network" && networkLabel ? "—" : counts[c.id]}</span>
          </button>
        ))}
      </div>
      {filter === "network" && networkLabel ? (
        <p className="rd-timeline-note">
          {session.network_status === "not_captured"
            ? "Network capture was off for this session, so there are no requests to show."
            : "Network capture was on, but no requests were made during this task."}
        </p>
      ) : visible.length === 0 ? (
        <p className="rd-timeline-note">No evidence of this kind in the session.</p>
      ) : (
        <ol ref={listRef} className="rd-timeline-list">
          {visible.map((item) => (
            <TimelineItem
              key={item.id}
              item={item}
              highlighted={highlighted.has(item.id)}
              selected={selection?.kind === "evidence" && selection.id === item.id}
              citedBy={model.citations.get(item.id)?.length ?? 0}
              onSelect={() => onSelect({ kind: "evidence", id: item.id })}
            />
          ))}
        </ol>
      )}
    </section>
  );
}

function TimelineItem({ item, highlighted, selected, citedBy, onSelect }: { item: EvidenceItem; highlighted: boolean; selected: boolean; citedBy: number; onSelect: () => void }) {
  const d = describeEvidence(item);
  return (
    <li data-highlighted={highlighted}>
      <button type="button" className={`rd-tl-item rd-tl-item--${item.kind}${highlighted ? " is-highlighted" : ""}`} aria-pressed={selected} onClick={onSelect}>
        <span className="rd-tl-time">{formatTimestamp(item.timestamp_ms)}</span>
        <span className="rd-tl-symbol" aria-hidden="true">{d.symbol}</span>
        <span className="rd-tl-text">
          <span className="rd-tl-title">{d.title}</span>
          <span className="rd-tl-detail">{d.detail}</span>
        </span>
        {citedBy > 0 && <span className="rd-tl-cited" title={`Cited by ${citedBy} graph ${citedBy === 1 ? "element" : "elements"}`}>{citedBy}</span>}
      </button>
    </li>
  );
}
