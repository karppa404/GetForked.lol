"use client";

import { useCallback, useEffect, useRef, useState, useSyncExternalStore } from "react";
import { isAbort } from "./http";
import type { Workspace } from "./workspace";

const noSubscription = () => () => {};
const noRealtime = () => "unavailable" as const;
export function useRealtimeStatus(workspace: Workspace) {
  return useSyncExternalStore(workspace.subscribe ?? noSubscription, workspace.realtimeStatus ?? noRealtime, noRealtime);
}

// ---------- hash routing (static-host friendly, deep-linkable, back button works) ----------

export type Route =
  | { name: "projects" }
  | { name: "project"; projectId: string }
  | { name: "session"; projectId: string; sessionId: string };

export function parseRoute(hash: string): Route {
  let parts: string[];
  try {
    parts = hash.replace(/^#\/?/, "").split("/").filter(Boolean).map(decodeURIComponent);
  } catch {
    return { name: "projects" };
  }
  if (parts[0] === "projects" && parts[1]) {
    if (parts[2] === "sessions" && parts[3]) return { name: "session", projectId: parts[1], sessionId: parts[3] };
    return { name: "project", projectId: parts[1] };
  }
  return { name: "projects" };
}

export function routeHref(route: Route): string {
  const e = encodeURIComponent;
  if (route.name === "project") return `#/projects/${e(route.projectId)}`;
  if (route.name === "session") return `#/projects/${e(route.projectId)}/sessions/${e(route.sessionId)}`;
  return "#/";
}

const subscribeHash = (cb: () => void) => {
  window.addEventListener("hashchange", cb);
  return () => window.removeEventListener("hashchange", cb);
};

export function useRoute(): Route {
  const hash = useSyncExternalStore(subscribeHash, () => window.location.hash, () => "");
  return parseRoute(hash);
}

// ---------- page visibility ----------

const subscribeVisibility = (cb: () => void) => {
  document.addEventListener("visibilitychange", cb);
  return () => document.removeEventListener("visibilitychange", cb);
};

export function usePageVisible(): boolean {
  return useSyncExternalStore(subscribeVisibility, () => document.visibilityState === "visible", () => true);
}

export function useNow(intervalMs: number, enabled = true): number {
  const [now, setNow] = useState(() => Date.now());
  useEffect(() => {
    if (!enabled) return;
    setNow(Date.now());
    const t = setInterval(() => setNow(Date.now()), intervalMs);
    return () => clearInterval(t);
  }, [intervalMs, enabled]);
  return now;
}

// ---------- cancellable resource loading ----------

export interface Resource<T> {
  data: T | undefined;
  error: unknown;
  loading: boolean;
  reload: () => void;
  setData: (update: (prev: T | undefined) => T | undefined) => void;
}

export function useResource<T>(key: string, load: (signal: AbortSignal) => Promise<T>): Resource<T> {
  const [state, setState] = useState<{ key: string; data?: T; error?: unknown; loading: boolean }>({ key, loading: true });
  const [nonce, setNonce] = useState(0);
  const loadRef = useRef(load);
  loadRef.current = load;

  useEffect(() => {
    const controller = new AbortController();
    setState((s) => (s.key === key ? { ...s, loading: true, error: undefined } : { key, loading: true }));
    loadRef.current(controller.signal).then(
      (data) => !controller.signal.aborted && setState({ key, data, loading: false }),
      (error) => {
        if (controller.signal.aborted || isAbort(error)) return;
        setState((s) => ({ key, data: s.key === key ? s.data : undefined, error, loading: false }));
      },
    );
    return () => controller.abort();
  }, [key, nonce]);

  const current = state.key === key ? state : { key, loading: true, data: undefined, error: undefined };
  return {
    data: current.data,
    error: current.error,
    loading: current.loading,
    reload: useCallback(() => setNonce((n) => n + 1), []),
    setData: useCallback((update) => setState((s) => ({ ...s, data: update(s.data) })), []),
  };
}

// ---------- bounded, visibility-aware polling ----------

export type PollStatus = "idle" | "polling" | "paused" | "exhausted" | "error";

/**
 * Polls `tick` every `intervalMs` while enabled and the page is visible, at most `maxAttempts`
 * times per `resetKey`. Errors halt polling (no silent retry loops); `restart` resumes.
 */
export function useBoundedPolling(opts: {
  enabled: boolean;
  intervalMs: number;
  maxAttempts: number;
  resetKey: string;
  tick: (signal: AbortSignal) => Promise<"continue" | "stop">;
}) {
  const { enabled, intervalMs, maxAttempts, resetKey } = opts;
  const visible = usePageVisible();
  const attempts = useRef(0);
  const tickRef = useRef(opts.tick);
  tickRef.current = opts.tick;
  const [halt, setHalt] = useState<{ key: string; reason: "exhausted" | "error"; error?: unknown } | null>(null);
  const [epoch, setEpoch] = useState(0);
  const halted = halt?.key === resetKey ? halt : null;

  useEffect(() => {
    attempts.current = 0;
  }, [resetKey]);

  useEffect(() => {
    if (!enabled || !visible || halted) return;
    const controller = new AbortController();
    let timer: ReturnType<typeof setTimeout> | undefined;
    const run = async () => {
      if (attempts.current >= maxAttempts) {
        setHalt({ key: resetKey, reason: "exhausted" });
        return;
      }
      attempts.current++;
      try {
        const result = await tickRef.current(controller.signal);
        if (controller.signal.aborted || result === "stop") return;
        timer = setTimeout(run, intervalMs);
      } catch (error) {
        if (controller.signal.aborted || isAbort(error)) return;
        setHalt({ key: resetKey, reason: "error", error });
      }
    };
    timer = setTimeout(run, intervalMs);
    return () => {
      controller.abort();
      clearTimeout(timer);
    };
  }, [enabled, visible, halted, intervalMs, maxAttempts, resetKey, epoch]);

  const status: PollStatus = !enabled ? "idle" : halted ? halted.reason : !visible ? "paused" : "polling";
  return {
    status,
    error: halted?.error,
    restart: useCallback(() => {
      attempts.current = 0;
      setHalt(null);
      setEpoch((e) => e + 1);
    }, []),
  };
}
