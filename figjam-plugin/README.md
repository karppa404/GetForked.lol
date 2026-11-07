# Retrace FigJam plugin (v1)

Imports a validated Retrace graph JSON (`GET /v1/sessions/{id}/graph?download=1`, corrections
applied) into the current FigJam page as **editable** shapes and connectors:

- screens: rounded rectangles; actions: ellipses (with the action's `network_status`);
  API calls: squares. One row per type, in graph order.
- connectors follow graph edges; `candidate` associations are dashed and labeled.
- every shape/connector stores its element ID and evidence IDs in plugin data
  (`getPluginData("retrace")`, shared namespace `retrace`: `element_id`, `evidence_ids`)
  and shows a short evidence caption. Human-corrected labels are marked ✎.
- network status, ambiguities and suggestions become sticky notes; suggestions are
  labeled "not observed".

The plugin validates before creating anything (schema version, unique IDs, non-empty evidence,
edges reference nodes, API edges must be `candidate`, `network_status` consistency) and has no
network access. It does not call Figma MCP or create remote boards.

## Build and load

```bash
cd figjam-plugin
npm install
npm run typecheck && npm test && npm run build    # writes dist/code.js
```

First create a development plugin in Figma and replace the placeholder `id` in `manifest.json`
with the ID Figma assigns to your plugin. The repository's `retrace-graph-import-dev` is not a
registered plugin ID. See [Figma's manifest documentation](https://developers.figma.com/docs/plugins/manifest/).

In the Figma desktop app, open a FigJam file → Plugins → Development → Import plugin from
manifest… → choose `figjam-plugin/manifest.json`. Run "Retrace Graph Import" and pick the JSON.
`test/fixtures/backend-graph.json` is a real backend output you can use to try it.
