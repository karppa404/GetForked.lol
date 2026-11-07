"use client";

import { useCallback, useEffect, useMemo, useRef, useState } from "react";
import { POLL } from "@/lib/dashboard/config";
import { exportFilename, formatDuration, validateGraph } from "@/lib/dashboard/graph";
import { describeError, isAbort } from "@/lib/dashboard/http";
import { routeHref, useBoundedPolling, useResource } from "@/lib/dashboard/hooks";
import type { Correction, SessionDetail } from "@/lib/dashboard/types";
import { EvidenceTimeline } from "./evidence-timeline";
import { GraphPanel } from "./graph-panel";
import { Inspector } from "./inspector";
import { BoardLink, JobProgress } from "./session-parts";
import { buildSessionModel, type Selection } from "./session-model";
import { ErrorNotice, LoadingBlock, NetworkBadge, Spinner, StatusPill, formatDate, useDashboard } from "./ui";

const isRunning = (s: SessionDetail | undefined) =>
  Boolean(s && ((s.job && (s.job.status === "queued" || s.job.status === "running")) || (!s.job && (s.status === "queued" || s.status === "analyzing"))));

type ExportState = { state: "idle" } | { state: "busy" } | { state: "invalid"; errors: string[] } | { state: "error"; message: string } | { state: "done"; warnings: string[] };

export function SessionView({ projectId, sessionId }: { projectId: string; sessionId: string }) {
  const { workspace } = useDashboard();
  const session = useResource(`session:${workspace.kind}:${sessionId}`, (signal) => workspace.getSession(sessionId, signal));
  const projects = useResource(`projects:${workspace.kind}`, (signal) => workspace.listProjects(signal));
  const projectName = projects.data?.find((p) => p.id === projectId)?.name ?? "Project";
  const [selection, setSelection] = useState<Selection>(null);
  const [pending, setPending] = useState<Map<string, string>>(new Map());
  const [analyzeState, setAnalyzeState] = useState<{ busy: boolean; error?: unknown; confirm?: boolean }>({ busy: false });
  const [exportState, setExportState] = useState<ExportState>({ state: "idle" });
  const latest = useRef<SessionDetail | undefined>(undefined);
  latest.current = session.data;
  const { setData } = session;

  useEffect(() => {
    if (session.data) document.title = `${session.data.task} — Retrace`;
  }, [session.data]);

  const running = isRunning(session.data);
  const poll = useBoundedPolling({
    enabled: running || (workspace.kind === "backend" && Boolean(session.data)),
    intervalMs: running ? POLL.jobIntervalMs : POLL.reviewIntervalMs,
    maxAttempts: running ? POLL.jobMaxAttempts : POLL.reviewMaxAttempts,
    resetKey: `${sessionId}:${session.data?.job?.id ?? "none"}:${running}`,
    tick: async (signal) => {
      const next = await workspace.getSession(sessionId, signal);
      setData(() => next);
      return workspace.kind === "backend" || isRunning(next) ? "continue" : "stop";
    },
  });

  // Preview: corrections from another tab arrive via storage events.
  useEffect(() => {
    if (!workspace.subscribe) return;
    const controller = new AbortController();
    const unsub = workspace.subscribe(() => {
      workspace.getSession(sessionId, controller.signal).then((next) => setData(() => next), () => {});
    });
    return () => {
      controller.abort();
      unsub();
    };
  }, [workspace, sessionId, setData]);

  const model = useMemo(() => (session.data ? buildSessionModel(session.data, pending) : null), [session.data, pending]);
  const modelRef = useRef(model);
  modelRef.current = model;

  const upsertCorrection = useCallback((c: Correction) => {
    setData((s) => s && { ...s, corrections: [...s.corrections.filter((x) => x.element_id !== c.element_id), c] });
  }, [setData]);

  const rename = useCallback(async (id: string, label: string) => {
    const m = modelRef.current;
    if (!m) return;
    const agent = m.agentLabel.get(id) ?? "";
    const hasCorrection = latest.current?.corrections.some((c) => c.element_id === id) ?? false;
    if (label === agent && !hasCorrection) return;
    setPending((p) => new Map(p).set(id, label));
    try {
      if (label === agent) {
        await workspace.clearCorrection(sessionId, id, agent);
        setData((s) => s && { ...s, corrections: s.corrections.filter((c) => c.element_id !== id) });
      } else {
        upsertCorrection(await workspace.correctLabel(sessionId, id, label));
      }
    } catch (e) {
      throw new Error(`Couldn’t save the label: ${describeError(e)}`);
    } finally {
      setPending((p) => {
        const n = new Map(p);
        n.delete(id);
        return n;
      });
    }
  }, [workspace, sessionId, setData, upsertCorrection]);

  const restore = useCallback((id: string) => rename(id, modelRef.current?.agentLabel.get(id) ?? ""), [rename]);

  async function analyze() {
    setAnalyzeState({ busy: true });
    try {
      const r = await workspace.analyze(sessionId);
      setData((s) => s && { ...s, status: "queued", job: { id: r.job_id, status: r.status || "queued", stages: (s.job?.stages ?? []).map((st) => ({ ...st, status: "pending" })), error: null } });
      const fresh = await workspace.getSession(sessionId).catch(() => null);
      if (fresh) setData(() => fresh);
      poll.restart();
      setAnalyzeState({ busy: false });
    } catch (e) {
      if (!isAbort(e)) setAnalyzeState({ busy: false, error: e });
    }
  }

  async function download() {
    const m = modelRef.current;
    if (!m) return;
    setExportState({ state: "busy" });
    try {
      const raw = await workspace.getGraphExport(sessionId);
      const result = validateGraph(raw, new Set(m.evidence.map((e) => e.id)));
      if (!result.ok) return setExportState({ state: "invalid", errors: result.errors });
      const blob = new Blob([JSON.stringify(raw, null, 2)], { type: "application/json" });
      const url = URL.createObjectURL(blob);
      const a = document.createElement("a");
      a.href = url;
      a.download = exportFilename(m.session);
      document.body.appendChild(a);
      a.click();
      a.remove();
      setTimeout(() => URL.revokeObjectURL(url), 1000);
      setExportState({ state: "done", warnings: result.warnings });
    } catch (e) {
      setExportState({ state: "error", message: describeError(e) });
    }
  }

  if (session.error && !session.data) {
    return (
      <div className="rd-page">
        <Crumbs projectId={projectId} projectName={projectName} />
        <ErrorNotice error={session.error} title="Couldn’t load this session" onRetry={session.reload} />
      </div>
    );
  }
  if (!model) return <div className="rd-page"><Crumbs projectId={projectId} projectName={projectName} /><LoadingBlock label="Loading session" /></div>;

  const s = model.session;
  const networkStageDone = s.job?.stages.some((st) => st.name === "network" && (st.status === "done" || st.status === "skipped")) ?? !running;
  const analyzed = Boolean(model.graph);

  return (
    <div className="rd-page rd-page--session">
      <Crumbs projectId={projectId} projectName={projectName} task={s.task} />
      <header className="rd-session-head">
        <div className="rd-session-title">
          <p className="rd-eyebrow"><span aria-hidden="true" /> SESSION · {s.app.name.toUpperCase()}</p>
          <h1>{s.task}</h1>
          <p className="rd-session-meta">
            <StatusPill status={s.status} />
            <NetworkBadge status={s.network_status} />
            <span>{formatDate(s.started_at, true)}</span>
            <span>{formatDuration(s.duration_ms)}</span>
            {s.app.bundle_id && <span className="rd-mono">{s.app.bundle_id}</span>}
          </p>
        </div>
        <div className="rd-session-actions">
          {analyzeState.confirm ? (
            <div className="rd-confirm" role="group" aria-label="Confirm re-run">
              <span>Re-run analysis? Your corrections are kept.</span>
              <button type="button" className="rd-btn rd-btn--small rd-btn--primary" onClick={analyze}>Re-run</button>
              <button type="button" className="rd-btn rd-btn--small rd-btn--ghost" onClick={() => setAnalyzeState({ busy: false })}>Cancel</button>
            </div>
          ) : running ? (
            <button type="button" className="rd-btn rd-btn--small" disabled><Spinner label="Analyzing" /> Analyzing…</button>
          ) : analyzed ? (
            <button type="button" className="rd-btn rd-btn--small rd-btn--ghost" onClick={() => setAnalyzeState({ busy: false, confirm: true })} disabled={analyzeState.busy}>Re-run analysis</button>
          ) : (
            <button type="button" className="rd-btn rd-btn--small rd-btn--primary" onClick={analyze} disabled={analyzeState.busy}>{analyzeState.busy ? "Starting…" : "Run analysis"}</button>
          )}
          <button type="button" className="rd-btn rd-btn--small" onClick={download} disabled={!analyzed || exportState.state === "busy"} title="Validated Graph v1 JSON for the FigJam import plugin">
            {exportState.state === "busy" ? "Validating…" : "Download graph JSON"} <span aria-hidden="true">↓</span>
          </button>
          <BoardLink sessionId={s.id} boardUrl={s.board_url} onSaved={(url) => setData((d) => d && { ...d, board_url: url })} />
        </div>
      </header>

      {analyzeState.error ? <ErrorNotice error={analyzeState.error} title="Couldn’t start analysis" onRetry={analyze} /> : null}
      <ExportFeedback state={exportState} onDismiss={() => setExportState({ state: "idle" })} preview={workspace.kind === "preview"} />
      {s.job && (running || s.job.status === "failed") && <JobProgress job={s.job} poll={poll} onRetryPoll={poll.restart} />}
      {!running && workspace.kind === "backend" && <p className="rd-fine rd-session-foot">
        {poll.status === "exhausted" ? <>Review updates paused. <button type="button" className="rd-link-btn" onClick={poll.restart}>Resume updates</button></> : poll.status === "paused" ? "Review updates pause while this tab is hidden." : "Review changes refresh every 5 seconds while this tab is visible."}
      </p>}
      {!running && poll.status === "error" && <ErrorNotice error={poll.error} title="Review updates stopped" onRetry={poll.restart} />}
      {session.error && session.data ? <ErrorNotice error={session.error} title="Showing the last loaded version" onRetry={session.reload} /> : null}

      <div className="rd-session-grid">
        <EvidenceTimeline model={model} selection={selection} onSelect={setSelection} />
        <GraphPanel model={model} selection={selection} onSelect={setSelection} onRename={rename} analysisRunning={running} networkStageDone={networkStageDone} onAnalyze={analyze} />
        <Inspector model={model} selection={selection} onSelect={setSelection} onRename={rename} onRestore={restore} />
      </div>
      {s.job?.status === "succeeded" && !running && <CompletedJobNote stages={s.job.stages.length} />}
    </div>
  );
}

function CompletedJobNote({ stages }: { stages: number }) {
  return <p className="rd-fine rd-session-foot">Analysis complete{stages ? ` · ${stages} stages published` : ""}. Corrections are stored separately from the agent’s graph and survive re-runs.</p>;
}

function ExportFeedback({ state, onDismiss, preview }: { state: ExportState; onDismiss: () => void; preview: boolean }) {
  if (state.state === "invalid") {
    return (
      <div className="rd-notice rd-notice--error" role="alert">
        <span className="rd-notice-icon" aria-hidden="true">!</span>
        <div>
          <strong>The graph didn’t pass validation, so it wasn’t downloaded</strong>
          <ul className="rd-validation">{state.errors.slice(0, 8).map((e) => <li key={e}>{e}</li>)}</ul>
          {state.errors.length > 8 && <p className="rd-fine">…and {state.errors.length - 8} more.</p>}
          <div className="rd-notice-actions"><button type="button" className="rd-btn rd-btn--small rd-btn--ghost" onClick={onDismiss}>Dismiss</button></div>
        </div>
      </div>
    );
  }
  if (state.state === "error") return <ErrorNotice error={new Error(state.message)} title="Couldn’t download the graph"><button type="button" className="rd-btn rd-btn--small rd-btn--ghost" onClick={onDismiss}>Dismiss</button></ErrorNotice>;
  if (state.state === "done") {
    return (
      <div className="rd-notice rd-notice--ok" role="status">
        <span className="rd-notice-icon" aria-hidden="true">✓</span>
        <div>
          <strong>Validated graph downloaded</strong>
          <p>{preview ? "Graph v1 JSON with your preview corrections applied, marked as sample data." : "Graph v1 JSON as returned by the API."} It passed reference checks and is ready for the FigJam import plugin.</p>
          {state.warnings.length > 0 && <ul className="rd-validation">{state.warnings.map((w) => <li key={w}>{w}</li>)}</ul>}
        </div>
        <button type="button" className="rd-icon-btn" onClick={onDismiss} aria-label="Dismiss">×</button>
      </div>
    );
  }
  return null;
}

function Crumbs({ projectId, projectName, task }: { projectId: string; projectName: string; task?: string }) {
  return (
    <nav className="rd-crumbs" aria-label="Breadcrumb">
      <a href="#/">Projects</a>
      <span aria-hidden="true">/</span>
      <a href={routeHref({ name: "project", projectId })}>{projectName}</a>
      <span aria-hidden="true">/</span>
      <span aria-current="page">{task ?? "Session"}</span>
    </nav>
  );
}
