"use client";

import { useState } from "react";

export function WorkflowPreview() {
  const [view, setView] = useState<"workflow" | "network">("workflow");
  return (
    <div className="preview-wrap" aria-label="Illustration of a Retrace analysis">
      <div className="floating-label"><span className="small-star">✳</span> The details are already there.<br /><span>Let’s connect them.</span></div>
      <div className="product-window">
        <div className="window-top"><span className="window-dots"><i /><i /><i /></span><span>retrace / appearance-settings</span><span className="example-label">EXAMPLE</span></div>
        <div className="product-body">
          <aside className="session-sidebar">
            <div className="sidebar-title"><span className="mini-logo">↶</span> Session 001</div>
            <div className="app-label"><span className="app-symbol">A</span><span>Acme Desktop<small>Appearance settings</small></span></div>
            <div className="tiny-heading">OBSERVED ACTIONS <span>03</span></div>
            <div className="event"><span className="event-dot" /><div>Open preferences<small>00:02 · Click</small></div><span>↗</span></div>
            <div className="event active"><span className="event-dot" /><div>Select dark mode<small>00:05 · Click</small></div><span>↗</span></div>
            <div className="event"><span className="event-dot" /><div>Appearance updated<small>00:06 · Screen change</small></div><span>↗</span></div>
            <div className="local-note"><span>◈</span> Every connection starts<br />with evidence.</div>
          </aside>
          <div className="canvas-panel">
            <div className="canvas-tabs" role="tablist" aria-label="Example graph type">
              <button id="workflow-tab" role="tab" aria-selected={view === "workflow"} aria-controls="graph-panel" onClick={() => setView("workflow")}>Workflow</button>
              <button id="network-tab" role="tab" aria-selected={view === "network"} aria-controls="graph-panel" onClick={() => setView("network")}>API dependencies</button>
            </div>
            <div className="graph-canvas" role="tabpanel" id="graph-panel" aria-labelledby={`${view}-tab`} tabIndex={0}>
              {view === "workflow" ? <>
                <div className="graph-node screen-node first-node"><div className="node-eyebrow"><span>▣</span> SCREEN STATE <span>01</span></div><div className="mini-screen"><div className="mini-sidebar" /><div className="mini-content"><b /><i /><i /><span /></div></div><strong>Light appearance</strong><small>Before the action</small></div>
                <div className="connector connector-one"><span>↓</span><small>click</small></div>
                <div className="action-node"><span>↖</span> Select “Dark”<span className="action-evidence">E02</span></div>
                <div className="connector connector-two"><span>↓</span><small>observed result</small></div>
                <div className="graph-node screen-node last-node"><div className="node-eyebrow"><span>▣</span> SCREEN STATE <span>02</span></div><div className="mini-screen dark"><div className="mini-sidebar" /><div className="mini-content"><b /><i /><i /><span /></div></div><strong>Dark appearance</strong><small>Change confirmed by frame E03</small></div>
                <div className="evidence-sticker"><span>✓</span> Observed, not assumed.</div>
              </> : <div className="network-example"><span className="network-symbol">⌁</span><strong>A local change.<br />No request needed.</strong><p>No network activity observed</p><small>API dependencies appear here when a recording includes network evidence.</small></div>}
              <div className="canvas-legend"><span /> {view === "workflow" ? "Evidence-linked workflow" : "Network evidence"}<span className="zoom-label">100% <b>− &nbsp; +</b></span></div>
            </div>
          </div>
        </div>
        <div className="window-bottom"><span><i /> Example visualization</span><span>03 evidence items <span className="bottom-separator">/</span> 02 screen states</span></div>
      </div>
      <div className="under-window-note"><span>↳</span> Less guesswork. More groundwork.</div>
    </div>
  );
}
