"use client";
import "@xyflow/react/dist/style.css";

import {
  Background,
  BackgroundVariant,
  Controls,
  Handle,
  MarkerType,
  Position,
  ReactFlow,
  ReactFlowProvider,
  applyNodeChanges,
  useReactFlow,
  type Edge,
  type Node,
  type NodeChange,
  type NodeProps,
} from "@xyflow/react";
import { memo, useCallback, useEffect, useMemo, useRef, useState } from "react";
import { layeredLayout, type GraphView } from "@/lib/dashboard/graph";
import { LabelEditor } from "./label-editor";
import { typeLabel, type Selection } from "./session-model";

export interface CanvasNodeData extends Record<string, unknown> {
  label: string;
  type: string;
  evidenceCount: number;
  edited: boolean;
  ambiguous: boolean;
  context: boolean;
  highlighted: boolean;
  onRename: (id: string, label: string) => Promise<void>;
}

type CanvasNode = Node<CanvasNodeData, "retrace">;

const RetraceNode = memo(function RetraceNode({ id, data, selected }: NodeProps<CanvasNode>) {
  const [editing, setEditing] = useState(false);
  const kind = data.type === "screen" ? "screen" : data.type === "action" ? "action" : "network";
  return (
    <div
      className={`rd-gnode rd-gnode--${kind}${selected ? " is-selected" : ""}${data.highlighted ? " is-highlighted" : ""}${data.context ? " is-context" : ""}`}
      onDoubleClick={(e) => {
        e.stopPropagation();
        setEditing(true);
      }}
      title="Double-click to rename"
    >
      <Handle type="target" position={Position.Top} className="rd-handle" isConnectable={false} />
      <div className="rd-gnode-type">
        {typeLabel(data.type)}
        {data.ambiguous && <span className="rd-gnode-flag" title="Has an open question">?</span>}
      </div>
      {editing ? (
        <LabelEditor compact initial={data.label} label={`Rename ${typeLabel(data.type)}`} onCancel={() => setEditing(false)} onSave={async (v) => { await data.onRename(id, v); setEditing(false); }} />
      ) : (
        <div className="rd-gnode-label">{data.label}</div>
      )}
      <div className="rd-gnode-foot">
        <span>{data.evidenceCount} {data.evidenceCount === 1 ? "source" : "sources"}</span>
        {data.edited && <span className="rd-edited-tag">Edited</span>}
      </div>
      <Handle type="source" position={Position.Bottom} className="rd-handle" isConnectable={false} />
    </div>
  );
});

const nodeTypes = { retrace: RetraceNode };

interface GraphCanvasProps {
  view: GraphView;
  selection: Selection;
  highlightedIds: Set<string>;
  editedIds: Set<string>;
  ambiguousIds: Set<string>;
  onSelect: (s: Selection) => void;
  onRename: (id: string, label: string) => Promise<void>;
  ariaLabel: string;
}

export function GraphCanvas(props: GraphCanvasProps) {
  return (
    <ReactFlowProvider>
      <CanvasInner {...props} />
    </ReactFlowProvider>
  );
}

function CanvasInner({ view, selection, highlightedIds, editedIds, ambiguousIds, onSelect, onRename, ariaLabel }: GraphCanvasProps) {
  const { fitView } = useReactFlow();
  const structureKey = view.nodes.map((n) => n.id).join("|") + "#" + view.edges.map((e) => e.id).join("|");
  // Layout depends only on structure, so relabeling never moves nodes.
  // eslint-disable-next-line react-hooks/exhaustive-deps
  const layout = useMemo(() => layeredLayout(view.nodes, view.edges, { direction: "TB" }), [structureKey]);
  const dragged = useRef<Record<string, { x: number; y: number }>>({});
  const selectedId = selection?.kind === "element" ? selection.id : null;

  const derived = useMemo<CanvasNode[]>(
    () =>
      view.nodes.map((n) => ({
        id: n.id,
        type: "retrace",
        position: dragged.current[n.id] ?? layout[n.id] ?? { x: 0, y: 0 },
        selected: n.id === selectedId,
        ariaLabel: `${typeLabel(n.type)}: ${n.label}`,
        data: {
          label: n.label,
          type: n.type,
          evidenceCount: n.evidence_ids.length,
          edited: editedIds.has(n.id),
          ambiguous: ambiguousIds.has(n.id),
          context: view.contextNodeIds.has(n.id),
          highlighted: highlightedIds.has(n.id),
          onRename,
        },
      })),
    [view, layout, selectedId, editedIds, ambiguousIds, highlightedIds, onRename],
  );

  const [nodes, setNodes] = useState<CanvasNode[]>(derived);
  useEffect(() => {
    setNodes((prev) => {
      const byId = new Map(prev.map((p) => [p.id, p]));
      return derived.map((d) => {
        const p = byId.get(d.id);
        return p ? { ...p, ...d, position: dragged.current[d.id] ?? d.position } : d;
      });
    });
  }, [derived]);

  useEffect(() => {
    const t = setTimeout(() => fitView({ padding: 0.18, duration: 0, maxZoom: 1.1 }), 30);
    return () => clearTimeout(t);
  }, [structureKey, fitView]);

  const edges = useMemo<Edge[]>(
    () =>
      view.edges.map((e) => {
        const candidate = e.association === "candidate";
        const active = e.id === selectedId || highlightedIds.has(e.id);
        return {
          id: e.id,
          source: e.source,
          target: e.target,
          label: editedIds.has(e.id) ? `${e.label} (edited)` : e.label,
          type: "smoothstep",
          selected: e.id === selectedId,
          ariaLabel: `${candidate ? "Candidate" : "Observed"} connection: ${e.label}`,
          className: `rd-gedge${candidate ? " rd-gedge--candidate" : ""}${active ? " is-active" : ""}`,
          markerEnd: { type: MarkerType.ArrowClosed, width: 16, height: 16, color: active || candidate ? "var(--rd-accent)" : "var(--rd-faint)" },
          labelBgPadding: [6, 3] as [number, number],
          labelBgBorderRadius: 4,
          interactionWidth: 18,
        };
      }),
    [view.edges, selectedId, highlightedIds, editedIds],
  );

  const onNodesChange = useCallback((changes: NodeChange<CanvasNode>[]) => {
    for (const c of changes) if (c.type === "position" && c.position) dragged.current[c.id] = c.position;
    setNodes((nds) => applyNodeChanges(changes, nds));
  }, []);

  const resetLayout = () => {
    dragged.current = {};
    setNodes(derived.map((d) => ({ ...d, position: layout[d.id] ?? d.position })));
    setTimeout(() => fitView({ padding: 0.18, duration: 0, maxZoom: 1.1 }), 30);
  };

  return (
    <div className="rd-canvas" aria-label={ariaLabel} role="region">
      <ReactFlow
        nodes={nodes}
        edges={edges}
        nodeTypes={nodeTypes}
        onNodesChange={onNodesChange}
        onNodeClick={(_, n) => onSelect({ kind: "element", id: n.id })}
        onEdgeClick={(_, e) => onSelect({ kind: "element", id: e.id })}
        onPaneClick={() => onSelect(null)}
        onSelectionChange={({ nodes: ns, edges: es }) => {
          const only = ns.length + es.length === 1 ? (ns[0] ?? es[0]) : null;
          if (only && only.id !== selectedId) onSelect({ kind: "element", id: only.id });
        }}
        nodesConnectable={false}
        deleteKeyCode={null}
        zoomOnDoubleClick={false}
        minZoom={0.25}
        maxZoom={1.75}
        fitView
        fitViewOptions={{ padding: 0.18, maxZoom: 1.1 }}
        proOptions={{ hideAttribution: true }}
      >
        <Background variant={BackgroundVariant.Dots} gap={16} size={1} />
        <Controls showInteractive={false} position="bottom-right" />
      </ReactFlow>
      <button type="button" className="rd-canvas-reset rd-btn rd-btn--ghost rd-btn--small" onClick={resetLayout}>Reset layout</button>
    </div>
  );
}
