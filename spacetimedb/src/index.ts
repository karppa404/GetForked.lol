/*
 * Retrace shared state module.
 *
 * Every table is PRIVATE (the SpacetimeDB default). Rows are written only by
 * trusted backend identities (the publishing owner identity is trusted at
 * init; further writers can be added by an existing trusted writer). Browsers
 * never receive table rows directly: they subscribe to per-viewer views that
 * filter by `ctx.sender` through `project_viewer`, a grant the backend creates
 * only after it has authenticated the browser user and checked project
 * ownership.
 *
 * No credentials, pairing codes, device tokens or raw evidence live here. Graph
 * documents are stored as validated JSON strings produced by the backend's
 * publisher (they are documents, not relational data). Human corrections are a
 * separate table keyed by (session_id, element_id) and are never touched by
 * agent reruns.
 */
import {
  schema,
  table,
  t,
  SenderError,
  type InferSchema,
  type ReducerCtx,
  type ViewCtx as StdbViewCtx,
} from 'spacetimedb/server';

const trustedWriter = table(
  { name: 'trusted_writer' },
  {
    identity: t.identity().primaryKey(),
    note: t.string(),
  }
);

const project = table(
  { name: 'project' },
  {
    projectId: t.string().primaryKey(),
    name: t.string(),
    ownerUserId: t.string().index('btree'),
    createdAt: t.string(),
  }
);

const projectViewer = table(
  {
    name: 'project_viewer',
    indexes: [{ accessor: 'by_viewer_project', algorithm: 'btree', columns: ['viewer', 'projectId'] }],
  },
  {
    grantId: t.u64().primaryKey().autoInc(),
    projectId: t.string().index('btree'),
    viewer: t.identity(),
    userId: t.string(),
  }
);

const session = table(
  { name: 'session' },
  {
    sessionId: t.string().primaryKey(),
    projectId: t.string().index('btree'),
    status: t.string(),
    appName: t.string(),
    bundleId: t.string(),
    task: t.string(),
    startedAt: t.string(),
    durationMs: t.u64(),
    frameCount: t.u32(),
    interactionCount: t.u32(),
    networkCount: t.u32(),
    networkCapture: t.string(),
    uploadedAt: t.string(),
    uploadedByDevice: t.string(),
  }
);

const evidenceRef = table(
  { name: 'evidence_ref' },
  {
    evidenceId: t.string().primaryKey(),
    sessionId: t.string().index('btree'),
    kind: t.string(),
    timestampMs: t.u64(),
    artifactKey: t.option(t.string()),
    summary: t.string(),
  }
);

const job = table(
  { name: 'job' },
  {
    jobId: t.string().primaryKey(),
    sessionId: t.string().index('btree'),
    status: t.string(),
    stage: t.string(),
    error: t.option(t.string()),
    callsUsed: t.u32(),
    promptTokens: t.u64(),
    completionTokens: t.u64(),
    usageEstimated: t.bool(),
    createdAt: t.string(),
    updatedAt: t.string(),
  }
);

const jobStage = table(
  {
    name: 'job_stage',
    indexes: [{ accessor: 'by_job_stage', algorithm: 'btree', columns: ['jobId', 'stage'] }],
  },
  {
    stageRowId: t.u64().primaryKey().autoInc(),
    jobId: t.string().index('btree'),
    sessionId: t.string().index('btree'),
    stage: t.string(),
    status: t.string(),
    summaryJson: t.string(),
    updatedAt: t.string(),
  }
);

const graphVersion = table(
  { name: 'graph_version' },
  {
    graphId: t.string().primaryKey(),
    sessionId: t.string().index('btree'),
    jobId: t.string(),
    version: t.u32(),
    networkStatus: t.string(),
    nodeCount: t.u32(),
    edgeCount: t.u32(),
    graphJson: t.string(),
    publishedAt: t.string(),
  }
);

const correction = table(
  { name: 'correction' },
  {
    correctionId: t.string().primaryKey(),
    sessionId: t.string().index('btree'),
    elementId: t.string(),
    label: t.string(),
    authorUserId: t.string(),
    updatedAt: t.string(),
  }
);

const spacetimedb = schema({
  trustedWriter,
  project,
  projectViewer,
  session,
  evidenceRef,
  job,
  jobStage,
  graphVersion,
  correction,
});
export default spacetimedb;

type Ctx = ReducerCtx<InferSchema<typeof spacetimedb>>;

const MAX_GRAPH_JSON = 512 * 1024;
const MAX_TEXT = 4096;

function requireTrusted(ctx: Ctx) {
  if (!ctx.db.trustedWriter.identity.find(ctx.sender)) {
    throw new SenderError('unauthorized: trusted backend writer required');
  }
}

function bounded(value: string, field: string, max = MAX_TEXT) {
  if (value.length > max) throw new SenderError(`${field} too long`);
  return value;
}

export const init = spacetimedb.init(ctx => {
  // The identity that publishes the module is the backend owner identity.
  ctx.db.trustedWriter.insert({ identity: ctx.sender, note: 'module publisher' });
});

export const add_trusted_writer = spacetimedb.reducer(
  { identity: t.identity(), note: t.string() },
  (ctx, { identity, note }) => {
    requireTrusted(ctx);
    if (!ctx.db.trustedWriter.identity.find(identity)) {
      ctx.db.trustedWriter.insert({ identity, note: bounded(note, 'note', 200) });
    }
  }
);

export const upsert_project = spacetimedb.reducer(
  { projectId: t.string(), name: t.string(), ownerUserId: t.string(), createdAt: t.string() },
  (ctx, args) => {
    requireTrusted(ctx);
    bounded(args.name, 'name', 200);
    if (ctx.db.project.projectId.find(args.projectId)) ctx.db.project.projectId.update(args);
    else ctx.db.project.insert(args);
  }
);

export const grant_viewer = spacetimedb.reducer(
  { projectId: t.string(), viewer: t.identity(), userId: t.string() },
  (ctx, { projectId, viewer, userId }) => {
    requireTrusted(ctx);
    if (!ctx.db.project.projectId.find(projectId)) throw new SenderError('unknown project');
    for (const g of ctx.db.projectViewer.by_viewer_project.filter([viewer, projectId])) {
      if (g.userId === userId) return;
    }
    ctx.db.projectViewer.insert({ grantId: 0n, projectId, viewer, userId });
  }
);

export const revoke_viewer = spacetimedb.reducer(
  { projectId: t.string(), viewer: t.identity() },
  (ctx, { projectId, viewer }) => {
    requireTrusted(ctx);
    for (const g of [...ctx.db.projectViewer.by_viewer_project.filter([viewer, projectId])]) {
      ctx.db.projectViewer.grantId.delete(g.grantId);
    }
  }
);

export const upsert_session = spacetimedb.reducer(
  {
    sessionId: t.string(),
    projectId: t.string(),
    status: t.string(),
    appName: t.string(),
    bundleId: t.string(),
    task: t.string(),
    startedAt: t.string(),
    durationMs: t.u64(),
    frameCount: t.u32(),
    interactionCount: t.u32(),
    networkCount: t.u32(),
    networkCapture: t.string(),
    uploadedAt: t.string(),
    uploadedByDevice: t.string(),
  },
  (ctx, args) => {
    requireTrusted(ctx);
    if (!ctx.db.project.projectId.find(args.projectId)) throw new SenderError('unknown project');
    bounded(args.task, 'task');
    const existing = ctx.db.session.sessionId.find(args.sessionId);
    if (existing) {
      if (existing.projectId !== args.projectId) throw new SenderError('session project mismatch');
      ctx.db.session.sessionId.update(args);
    } else ctx.db.session.insert(args);
  }
);

const EvidenceRefInput = t.object('EvidenceRefInput', {
  evidenceId: t.string(),
  kind: t.string(),
  timestampMs: t.u64(),
  artifactKey: t.option(t.string()),
  summary: t.string(),
});

export const add_evidence_refs = spacetimedb.reducer(
  { sessionId: t.string(), refs: t.array(EvidenceRefInput) },
  (ctx, { sessionId, refs }) => {
    requireTrusted(ctx);
    if (!ctx.db.session.sessionId.find(sessionId)) throw new SenderError('unknown session');
    if (refs.length > 10000) throw new SenderError('too many evidence refs');
    for (const r of refs) {
      const row = { ...r, sessionId, summary: bounded(r.summary, 'summary', 500) };
      const existing = ctx.db.evidenceRef.evidenceId.find(r.evidenceId);
      if (existing) {
        if (existing.sessionId !== sessionId) throw new SenderError('evidence id collision');
        ctx.db.evidenceRef.evidenceId.update(row);
      } else ctx.db.evidenceRef.insert(row);
    }
  }
);

export const upsert_job = spacetimedb.reducer(
  {
    jobId: t.string(),
    sessionId: t.string(),
    status: t.string(),
    stage: t.string(),
    error: t.option(t.string()),
    callsUsed: t.u32(),
    promptTokens: t.u64(),
    completionTokens: t.u64(),
    usageEstimated: t.bool(),
    createdAt: t.string(),
    updatedAt: t.string(),
  },
  (ctx, args) => {
    requireTrusted(ctx);
    if (!ctx.db.session.sessionId.find(args.sessionId)) throw new SenderError('unknown session');
    const row = { ...args, error: args.error ?? undefined };
    if (ctx.db.job.jobId.find(args.jobId)) ctx.db.job.jobId.update(row);
    else ctx.db.job.insert(row);
  }
);

export const record_job_stage = spacetimedb.reducer(
  {
    jobId: t.string(),
    stage: t.string(),
    status: t.string(),
    summaryJson: t.string(),
    updatedAt: t.string(),
  },
  (ctx, args) => {
    requireTrusted(ctx);
    const j = ctx.db.job.jobId.find(args.jobId);
    if (!j) throw new SenderError('unknown job');
    bounded(args.summaryJson, 'summaryJson', 64 * 1024);
    for (const existing of ctx.db.jobStage.by_job_stage.filter([args.jobId, args.stage])) {
      ctx.db.jobStage.stageRowId.update({ ...existing, ...args, sessionId: j.sessionId });
      return;
    }
    ctx.db.jobStage.insert({ stageRowId: 0n, sessionId: j.sessionId, ...args });
  }
);

export const publish_graph = spacetimedb.reducer(
  {
    graphId: t.string(),
    sessionId: t.string(),
    jobId: t.string(),
    version: t.u32(),
    networkStatus: t.string(),
    nodeCount: t.u32(),
    edgeCount: t.u32(),
    graphJson: t.string(),
    publishedAt: t.string(),
  },
  (ctx, args) => {
    requireTrusted(ctx);
    if (!ctx.db.session.sessionId.find(args.sessionId)) throw new SenderError('unknown session');
    bounded(args.graphJson, 'graphJson', MAX_GRAPH_JSON);
    if (!['observed', 'none_observed', 'not_captured'].includes(args.networkStatus)) {
      throw new SenderError('invalid network status');
    }
    // Graph versions are append-only; corrections are never modified here.
    if (ctx.db.graphVersion.graphId.find(args.graphId)) throw new SenderError('graph version exists');
    ctx.db.graphVersion.insert(args);
  }
);

export const set_correction = spacetimedb.reducer(
  {
    correctionId: t.string(),
    sessionId: t.string(),
    elementId: t.string(),
    label: t.string(),
    authorUserId: t.string(),
    updatedAt: t.string(),
  },
  (ctx, args) => {
    requireTrusted(ctx);
    if (!ctx.db.session.sessionId.find(args.sessionId)) throw new SenderError('unknown session');
    bounded(args.label, 'label', 500);
    if (ctx.db.correction.correctionId.find(args.correctionId)) ctx.db.correction.correctionId.update(args);
    else ctx.db.correction.insert(args);
  }
);

export const delete_correction = spacetimedb.reducer(
  { correctionId: t.string() },
  (ctx, { correctionId }) => {
    requireTrusted(ctx);
    ctx.db.correction.correctionId.delete(correctionId);
  }
);

/* ---------- Per-viewer views (the only thing browsers can subscribe to) ---------- */

type ViewCtx = StdbViewCtx<InferSchema<typeof spacetimedb>>;

function viewerProjectIds(ctx: ViewCtx): Set<string> {
  const ids = new Set<string>();
  for (const g of ctx.db.projectViewer.iter()) {
    if (g.viewer.equals(ctx.sender)) ids.add(g.projectId);
  }
  return ids;
}

function viewerSessionIds(ctx: ViewCtx): Set<string> {
  const projects = viewerProjectIds(ctx);
  const ids = new Set<string>();
  for (const pid of projects) for (const s of ctx.db.session.projectId.filter(pid)) ids.add(s.sessionId);
  return ids;
}

export const my_projects = spacetimedb.view(
  { name: 'my_projects', public: true },
  t.array(project.rowType),
  ctx => {
    const out = [];
    for (const pid of viewerProjectIds(ctx)) {
      const p = ctx.db.project.projectId.find(pid);
      if (p) out.push(p);
    }
    return out;
  }
);

export const my_sessions = spacetimedb.view(
  { name: 'my_sessions', public: true },
  t.array(session.rowType),
  ctx => {
    const out = [];
    for (const pid of viewerProjectIds(ctx)) out.push(...ctx.db.session.projectId.filter(pid));
    return out;
  }
);

export const my_jobs = spacetimedb.view(
  { name: 'my_jobs', public: true },
  t.array(job.rowType),
  ctx => {
    const out = [];
    for (const sid of viewerSessionIds(ctx)) out.push(...ctx.db.job.sessionId.filter(sid));
    return out;
  }
);

export const my_job_stages = spacetimedb.view(
  { name: 'my_job_stages', public: true },
  t.array(jobStage.rowType),
  ctx => {
    const out = [];
    for (const sid of viewerSessionIds(ctx)) out.push(...ctx.db.jobStage.sessionId.filter(sid));
    return out;
  }
);

export const my_graphs = spacetimedb.view(
  { name: 'my_graphs', public: true },
  t.array(graphVersion.rowType),
  ctx => {
    const out = [];
    for (const sid of viewerSessionIds(ctx)) out.push(...ctx.db.graphVersion.sessionId.filter(sid));
    return out;
  }
);

export const my_corrections = spacetimedb.view(
  { name: 'my_corrections', public: true },
  t.array(correction.rowType),
  ctx => {
    const out = [];
    for (const sid of viewerSessionIds(ctx)) out.push(...ctx.db.correction.sessionId.filter(sid));
    return out;
  }
);

export const my_evidence_refs = spacetimedb.view(
  { name: 'my_evidence_refs', public: true },
  t.array(evidenceRef.rowType),
  ctx => {
    const out = [];
    for (const sid of viewerSessionIds(ctx)) out.push(...ctx.db.evidenceRef.sessionId.filter(sid));
    return out;
  }
);
