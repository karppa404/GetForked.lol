"use client";

import { useEffect, useRef, useState } from "react";
import { POLL } from "@/lib/dashboard/config";
import { describeError, isAbort } from "@/lib/dashboard/http";
import { useBoundedPolling, useNow } from "@/lib/dashboard/hooks";
import type { Pairing, PairingClaim } from "@/lib/dashboard/types";
import { ErrorNotice, Spinner, useDashboard } from "./ui";

function remaining(expiresAt: string, now: number) {
  const ms = new Date(expiresAt).getTime() - now;
  return Number.isFinite(ms) ? ms : 0;
}

function countdown(ms: number) {
  const s = Math.max(0, Math.ceil(ms / 1000));
  return `${Math.floor(s / 60)}:${String(s % 60).padStart(2, "0")}`;
}

export function ConnectRecorder({ projectId }: { projectId: string }) {
  const { workspace } = useDashboard();
  const [pairing, setPairing] = useState<Pairing | null>(null);
  const [creating, setCreating] = useState(false);
  const [error, setError] = useState<unknown>(null);
  const abort = useRef<AbortController | null>(null);
  const now = useNow(1000, Boolean(pairing));

  useEffect(() => () => abort.current?.abort(), []);

  const msLeft = pairing ? remaining(pairing.expires_at, now) : 0;
  const expired = Boolean(pairing) && msLeft <= 0;
  const approved = pairing?.claims.some((c) => c.status === "approved") ?? false;

  const poll = useBoundedPolling({
    enabled: Boolean(pairing) && !expired && !approved,
    intervalMs: POLL.pairingIntervalMs,
    maxAttempts: Math.ceil((10 * 60_000) / POLL.pairingIntervalMs) + 5,
    resetKey: pairing?.pairing_id ?? "none",
    tick: async (signal) => {
      if (!pairing) return "stop";
      const next = await workspace.getPairing(pairing.pairing_id, signal);
      setPairing((p) => (p && p.pairing_id === next.pairing_id ? { ...p, ...next, code: next.code || p.code, expires_at: next.expires_at || p.expires_at } : p));
      return "continue";
    },
  });

  async function generate() {
    abort.current?.abort();
    abort.current = new AbortController();
    setCreating(true);
    setError(null);
    try {
      setPairing(await workspace.createPairing(projectId, abort.current.signal));
    } catch (e) {
      if (!isAbort(e)) setError(e);
    } finally {
      setCreating(false);
    }
  }

  return (
    <aside className="rd-connect" aria-labelledby="rd-connect-title">
      <div className="rd-connect-head">
        <span className="rd-connect-symbol" aria-hidden="true">⌘</span>
        <div>
          <h2 id="rd-connect-title">Connect a recorder</h2>
          <p>Pair the Retrace menu bar app on your Mac with this project using a one-time room code.</p>
        </div>
      </div>

      {error ? <ErrorNotice error={error} title="Couldn’t create a room code" onRetry={generate} /> : null}

      {!pairing ? (
        <button type="button" className="rd-btn rd-btn--primary rd-btn--wide" onClick={generate} disabled={creating}>
          {creating ? <><Spinner label="Creating code" /> Creating code…</> : <>Generate room code <span aria-hidden="true">↗</span></>}
        </button>
      ) : (
        <div className={`rd-room${expired ? " rd-room--expired" : ""}`}>
          <p className="rd-room-label">Room code</p>
          <p className="rd-room-code" aria-label={`Room code ${pairing.code.split("").join(" ")}`}>
            {pairing.code.split("").map((ch, i) => <span key={i}>{ch}</span>)}
          </p>
          <p className="rd-room-expiry" aria-live="polite">
            {approved ? "Code used" : expired ? "This code has expired." : <>Expires in <b>{countdown(msLeft)}</b> · single use</>}
          </p>

          {!approved && !expired && (
            <ol className="rd-steps-list rd-steps-list--compact">
              <li>Open Retrace from the menu bar on your Mac.</li>
              <li>Choose <b>Connect to workspace</b> and enter the code.</li>
              <li>Approve the device below when its name appears.</li>
            </ol>
          )}

          <ClaimList pairing={pairing} onApproved={(claimId) => setPairing((p) => p && { ...p, claims: p.claims.map((c) => (c.claim_id === claimId ? { ...c, status: "approved" } : c)) })} />

          {!approved && !expired && pairing.claims.length === 0 && (
            <p className="rd-waiting" role="status">
              {poll.status === "polling" && <><Spinner label="Waiting" /> Waiting for your Mac…</>}
              {poll.status === "paused" && "Paused while this tab is in the background."}
              {poll.status === "exhausted" && <>Stopped checking. <button type="button" className="rd-link-btn" onClick={poll.restart}>Check again</button></>}
            </p>
          )}
          {poll.status === "error" && <ErrorNotice error={poll.error} title="Lost contact while waiting" onRetry={poll.restart} />}

          {workspace.kind === "preview" && !approved && !expired && pairing.claims.length === 0 && (
            <div className="rd-preview-callout">
              <p>Preview: no real Mac can join this sample code.</p>
              <button type="button" className="rd-btn rd-btn--ghost rd-btn--small" onClick={async () => {
                  workspace.simulateClaim?.(pairing.pairing_id);
                  try {
                    setPairing(await workspace.getPairing(pairing.pairing_id));
                  } catch (e) {
                    setError(e);
                  }
                }}>
                Simulate a recorder claim
              </button>
            </div>
          )}

          {(expired || approved) && (
            <button type="button" className="rd-btn rd-btn--ghost rd-btn--wide" onClick={generate} disabled={creating}>
              {approved ? "Connect another device" : "Generate a new code"}
            </button>
          )}
        </div>
      )}
    </aside>
  );
}

function ClaimList({ pairing, onApproved }: { pairing: Pairing; onApproved: (claimId: string) => void }) {
  if (pairing.claims.length === 0) return null;
  return (
    <ul className="rd-claims" aria-label="Devices requesting access">
      {pairing.claims.map((c) => <ClaimRow key={c.claim_id} pairingId={pairing.pairing_id} claim={c} onApproved={onApproved} />)}
    </ul>
  );
}

function ClaimRow({ pairingId, claim, onApproved }: { pairingId: string; claim: PairingClaim; onApproved: (claimId: string) => void }) {
  const { workspace } = useDashboard();
  const [confirming, setConfirming] = useState(false);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const abort = useRef<AbortController | null>(null);
  useEffect(() => () => abort.current?.abort(), []);

  async function approve() {
    abort.current = new AbortController();
    setBusy(true);
    setError(null);
    try {
      await workspace.approveClaim(pairingId, claim.claim_id, abort.current.signal);
      onApproved(claim.claim_id);
    } catch (e) {
      if (!isAbort(e)) setError(describeError(e));
    } finally {
      setBusy(false);
      setConfirming(false);
    }
  }

  const approved = claim.status === "approved";
  return (
    <li className={`rd-claim${approved ? " rd-claim--approved" : ""}`}>
      <span className="rd-claim-icon" aria-hidden="true">{approved ? "✓" : "◌"}</span>
      <div className="rd-claim-main">
        <strong>{claim.device_name}</strong>
        <span className="rd-muted">{approved ? "Connected — this Mac can now upload sessions to this project." : "Wants to connect to this project"}</span>
        {confirming && !approved && (
          <p className="rd-claim-confirm">Only approve if you recognize <b>{claim.device_name}</b> and just entered this code on it.</p>
        )}
        {error && <p className="rd-form-error" role="alert">{error}</p>}
      </div>
      {!approved && (
        <div className="rd-claim-actions">
          {confirming ? (
            <>
              <button type="button" className="rd-btn rd-btn--primary rd-btn--small" onClick={approve} disabled={busy}>{busy ? "Approving…" : "Approve"}</button>
              <button type="button" className="rd-btn rd-btn--ghost rd-btn--small" onClick={() => setConfirming(false)} disabled={busy}>Cancel</button>
            </>
          ) : (
            <button type="button" className="rd-btn rd-btn--small" onClick={() => setConfirming(true)}>Review</button>
          )}
        </div>
      )}
    </li>
  );
}
