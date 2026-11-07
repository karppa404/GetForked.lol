"use client";

import { useEffect, useRef, useState, type FormEvent } from "react";
import { POLL } from "@/lib/dashboard/config";
import { describeError, isAbort } from "@/lib/dashboard/http";
import type { PollStatus } from "@/lib/dashboard/hooks";
import type { Job } from "@/lib/dashboard/types";
import { ErrorNotice, Spinner, useDashboard } from "./ui";

const STAGE_SYMBOL: Record<string, string> = { done: "✓", running: "", failed: "!", skipped: "–", pending: "" };

export function JobProgress({ job, poll, onRetryPoll }: { job: Job; poll: { status: PollStatus; error?: unknown }; onRetryPoll: () => void }) {
  const running = job.status === "queued" || job.status === "running";
  const failed = job.status === "failed";
  const doneCount = job.stages.filter((s) => s.status === "done" || s.status === "skipped").length;
  return (
    <section className={`rd-job${running ? " is-running" : ""}${failed ? " is-failed" : ""}`} aria-label="Analysis progress">
      <div className="rd-job-status" aria-live="polite">
        <strong>{running ? (job.status === "queued" ? "Analysis queued" : "Analyzing") : failed ? "Analysis failed" : job.status === "succeeded" ? "Analysis complete" : job.status}</strong>
        {job.stages.length > 0 && <span className="rd-muted">{doneCount} of {job.stages.length} stages</span>}
        {running && (
          <span className="rd-muted rd-job-poll">
            {poll.status === "polling" && <>Checking every {POLL.jobIntervalMs / 1000}s while this tab is open</>}
            {poll.status === "paused" && <>Paused while this tab is in the background</>}
            {poll.status === "exhausted" && <>Stopped checking after a few minutes. <button type="button" className="rd-link-btn" onClick={onRetryPoll}>Check again</button></>}
          </span>
        )}
      </div>
      {job.stages.length > 0 ? (
        <ol className="rd-stages">
          {job.stages.map((s) => (
            <li key={s.name} className={`rd-stage rd-stage--${s.status}`} title={s.detail}>
              <span className="rd-stage-mark" aria-hidden="true">{s.status === "running" ? <Spinner label="" /> : STAGE_SYMBOL[s.status] ?? ""}</span>
              <span className="rd-stage-label">{s.label ?? s.name}</span>
              <span className="rd-visually-hidden">: {s.status}{s.detail ? `, ${s.detail}` : ""}</span>
            </li>
          ))}
        </ol>
      ) : running ? (
        <div className="rd-job-bar" aria-hidden="true"><span /></div>
      ) : null}
      {failed && job.error && <p className="rd-form-error">{job.error}</p>}
      {poll.status === "error" && <ErrorNotice error={poll.error} title="Lost contact with the analysis job" onRetry={onRetryPoll} />}
    </section>
  );
}

export function validBoardUrl(v: string): string | null {
  try {
    const u = new URL(v);
    return u.protocol === "https:" && !u.username && !u.password && /(^|\.)figma\.com$/.test(u.hostname) ? u.toString() : null;
  } catch {
    return null;
  }
}

export function BoardLink({ sessionId, boardUrl, onSaved }: { sessionId: string; boardUrl: string | null; onSaved: (url: string | null) => void }) {
  const { workspace } = useDashboard();
  const [editing, setEditing] = useState(false);
  const [value, setValue] = useState(boardUrl ?? "");
  const [busy, setBusy] = useState(false);
  const [message, setMessage] = useState<{ tone: "error" | "info"; text: string } | null>(null);
  const abort = useRef<AbortController | null>(null);
  useEffect(() => () => abort.current?.abort(), []);

  async function save(url: string | null) {
    abort.current = new AbortController();
    setBusy(true);
    setMessage(null);
    try {
      const r = await workspace.saveBoardUrl(sessionId, url, abort.current.signal);
      if (r.status === "unsupported") {
        setMessage({ tone: "info", text: "This API doesn’t store board links yet, so it wasn’t saved." });
      } else {
        onSaved(r.board_url);
        setEditing(false);
      }
    } catch (e) {
      if (!isAbort(e)) setMessage({ tone: "error", text: describeError(e) });
    } finally {
      setBusy(false);
    }
  }

  function submit(e: FormEvent) {
    e.preventDefault();
    const url = validBoardUrl(value.trim());
    if (!url) return setMessage({ tone: "error", text: "Enter an https:// link to your FigJam board." });
    void save(url);
  }

  const safeBoardUrl = boardUrl ? validBoardUrl(boardUrl) : null;

  return (
    <div className="rd-board">
      {editing ? (
        <form onSubmit={submit} className="rd-board-form">
          <label htmlFor="rd-board-url" className="rd-visually-hidden">FigJam board URL</label>
          <input id="rd-board-url" type="url" inputMode="url" placeholder="https://www.figma.com/board/…" value={value} onChange={(e) => setValue(e.target.value)} disabled={busy} autoFocus onKeyDown={(e) => e.key === "Escape" && setEditing(false)} />
          <button type="submit" className="rd-btn rd-btn--small rd-btn--primary" disabled={busy}>{busy ? "Saving…" : "Save"}</button>
          {boardUrl && <button type="button" className="rd-btn rd-btn--small rd-btn--ghost" disabled={busy} onClick={() => save(null)}>Remove</button>}
          <button type="button" className="rd-btn rd-btn--small rd-btn--ghost" disabled={busy} onClick={() => { setEditing(false); setMessage(null); }}>Cancel</button>
        </form>
      ) : safeBoardUrl ? (
        <div className="rd-board-view">
          <a className="rd-btn rd-btn--small" href={safeBoardUrl} target="_blank" rel="noopener noreferrer">Open FigJam board <span aria-hidden="true">↗</span></a>
          <button type="button" className="rd-link-btn" onClick={() => { setValue(safeBoardUrl); setEditing(true); }}>Change</button>
        </div>
      ) : (
        <button type="button" className="rd-btn rd-btn--small rd-btn--ghost" onClick={() => { setValue(""); setEditing(true); }}>Add board link</button>
      )}
      {message && <p className={message.tone === "error" ? "rd-form-error" : "rd-fine"} role={message.tone === "error" ? "alert" : "status"}>{message.text}</p>}
    </div>
  );
}
