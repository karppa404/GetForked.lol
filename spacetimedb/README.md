# Retrace SpacetimeDB module

TypeScript module (SpacetimeDB 2.14) holding shared, private Retrace state: projects,
sessions, evidence references, jobs, incremental stage results, append-only graph
versions, human corrections (a separate table that agent reruns never touch) and board links.

- All tables are private. Reducers require the caller to be in `trusted_writer`. The publisher
  identity (the backend owner) is added at `init`, and `add_trusted_writer` can add more.
- Browsers read only the per-viewer views (`my_projects`, `my_sessions`, `my_evidence_refs`,
  `my_jobs`, `my_job_stages`, `my_graphs`, `my_corrections`, `my_session_boards`). These views
  filter by `ctx.sender` through `project_viewer` grants, which the backend creates after
  authenticating the user.
- No credentials, pairing codes, device tokens, screenshots or raw network bodies are stored here.

```bash
npm install
npm run typecheck
npm run build            # spacetime build
../backend/scripts/spacetime_local_dev.sh http://127.0.0.1:3000 retrace-dev   # publish locally
```
Generate dashboard bindings with
`spacetime generate --lang typescript --out-dir <web path> --module-path .`.
That output is owned by the web branch.
