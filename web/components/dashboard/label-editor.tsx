"use client";

import { useEffect, useId, useRef, useState, type FormEvent } from "react";

export function LabelEditor({ initial, onSave, onCancel, label = "Label", compact = false }: { initial: string; onSave: (v: string) => Promise<void> | void; onCancel: () => void; label?: string; compact?: boolean }) {
  const [value, setValue] = useState(initial);
  const [error, setError] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);
  const input = useRef<HTMLInputElement>(null);
  const id = useId();

  useEffect(() => {
    input.current?.focus();
    input.current?.select();
  }, []);

  async function submit(e?: FormEvent) {
    e?.preventDefault();
    const v = value.trim();
    if (!v) return setError("Label can’t be empty.");
    if (v.length > 140) return setError("Keep labels under 140 characters.");
    if (v === initial.trim()) return onCancel();
    setBusy(true);
    setError(null);
    try {
      await onSave(v);
    } catch (err) {
      setError(err instanceof Error ? err.message : "Couldn’t save");
      setBusy(false);
    }
  }

  return (
    <form className={`rd-label-editor nodrag nowheel${compact ? " rd-label-editor--compact" : ""}`} onSubmit={submit} onClick={(e) => e.stopPropagation()} onDoubleClick={(e) => e.stopPropagation()}>
      <label className="rd-visually-hidden" htmlFor={id}>{label}</label>
      <input
        id={id}
        ref={input}
        value={value}
        disabled={busy}
        onChange={(e) => setValue(e.target.value)}
        onKeyDown={(e) => {
          e.stopPropagation();
          if (e.key === "Escape") onCancel();
        }}
        aria-invalid={Boolean(error)}
      />
      <div className="rd-label-editor-actions">
        <button type="submit" className="rd-btn rd-btn--primary rd-btn--small" disabled={busy}>{busy ? "Saving…" : "Save"}</button>
        <button type="button" className="rd-btn rd-btn--ghost rd-btn--small" onClick={onCancel} disabled={busy}>Cancel</button>
      </div>
      {error && <p className="rd-form-error" role="alert">{error}</p>}
    </form>
  );
}
