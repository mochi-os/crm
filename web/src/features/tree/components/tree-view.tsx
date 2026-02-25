// Mochi CRMs: Tree view component
// Copyright Alistair Cunningham 2026

import { useState, useMemo, useEffect, useLayoutEffect, useCallback, useRef } from "react";
import { Button, EmptyState } from "@mochi/common";
import { Folder, Plus } from 'lucide-react';
import { TreeRow } from "./tree-row";
import type { CrmDetails, CrmObject, SortState } from "@/types";

interface TreeViewProps {
  crm: CrmDetails;
  crmId: string;
  objects: CrmObject[];
  peopleMap: Record<string, string>;
  viewFields?: string;
  sort?: SortState | null;
  onCardClick: (object: CrmObject) => void;
  onReparent?: (objectId: string, newParentId: string | null) => void;
  onReorder?: (objectId: string, newRank: number) => void;
  onCreateClick?: () => void;
}

export interface TreeNode {
  object: CrmObject;
  children: TreeNode[];
  depth: number;
  parent: string;
}

// Build tree structure from flat list of objects
function buildTree(objects: CrmObject[], sort?: SortState | null): TreeNode[] {
  const objectMap = new Map<string, CrmObject>();
  const childrenMap = new Map<string, CrmObject[]>();

  // Index all objects
  for (const obj of objects) {
    objectMap.set(obj.id, obj);
  }

  // Group by parent, promoting to root if parent is not in the set
  for (const obj of objects) {
    const parentId = obj.parent && objectMap.has(obj.parent) ? obj.parent : "";
    if (!childrenMap.has(parentId)) {
      childrenMap.set(parentId, []);
    }
    childrenMap.get(parentId)!.push(obj);
  }

  // Sort comparator based on sort state
  const sortField = sort?.field || "rank";
  const sortDirection = sort?.direction || "asc";
  const multiplier = sortDirection === "asc" ? 1 : -1;

  const compare = (a: CrmObject, b: CrmObject): number => {
    let aVal: string | number;
    let bVal: string | number;

    if (sortField === "rank") {
      aVal = a.rank || 0;
      bVal = b.rank || 0;
    } else if (sortField === "created") {
      aVal = a.created || 0;
      bVal = b.created || 0;
    } else if (sortField === "updated") {
      aVal = a.updated || 0;
      bVal = b.updated || 0;
    } else {
      const fieldId = sortField.startsWith("field:") ? sortField.slice(6) : sortField;
      aVal = a.values[fieldId] || "";
      bVal = b.values[fieldId] || "";
    }

    if (typeof aVal === "number" && typeof bVal === "number") {
      return (aVal - bVal) * multiplier;
    }
    return String(aVal).localeCompare(String(bVal)) * multiplier;
  };

  // Recursively build tree nodes
  function buildNodes(parentId: string, depth: number): TreeNode[] {
    const children = childrenMap.get(parentId) || [];
    children.sort(compare);

    return children.map((obj) => ({
      object: obj,
      children: buildNodes(obj.id, depth + 1),
      depth,
      parent: parentId,
    }));
  }

  return buildNodes("", 0);
}

interface FlatNode {
  node: TreeNode;
  hasChildren: boolean;
  isExpanded: boolean;
  siblings: CrmObject[];
  anySiblingHasChildren: boolean;
}

// Flatten tree for rendering, respecting expanded state
function flattenTree(nodes: TreeNode[], expanded: Set<string>): FlatNode[] {
  const result: FlatNode[] = [];

  function traverse(nodeList: TreeNode[]) {
    const siblings = nodeList.map((n) => n.object);
    const anySiblingHasChildren = nodeList.some((n) => n.children.length > 0);
    for (const node of nodeList) {
      const hasChildren = node.children.length > 0;
      const isExpanded = expanded.has(node.object.id);
      result.push({ node, hasChildren, isExpanded, siblings, anySiblingHasChildren });

      if (hasChildren && isExpanded) {
        traverse(node.children);
      }
    }
  }

  traverse(nodes);
  return result;
}

// Calculate rank for inserting at a position between siblings
function calculateRank(siblings: CrmObject[], insertIndex: number): number {
  const prevItem = insertIndex > 0 ? siblings[insertIndex - 1] : null;
  const nextItem = insertIndex < siblings.length ? siblings[insertIndex] : null;

  const prevRank = prevItem?.rank ?? 0;
  const nextRank = nextItem?.rank ?? prevRank + 1000;

  // Insert midway between prev and next
  return Math.floor((prevRank + nextRank) / 2);
}

export function TreeView({
  crm,
  crmId,
  objects,
  peopleMap,
  viewFields,
  sort,
  onCardClick,
  onReparent,
  onReorder,
  onCreateClick,
}: TreeViewProps) {
  // Storage key for expanded state
  const storageKey = `crms:${crmId}:tree:expanded`;

  // Load expanded state from localStorage
  const [expanded, setExpanded] = useState<Set<string>>(() => {
    try {
      const saved = localStorage.getItem(storageKey);
      return new Set(saved ? JSON.parse(saved) : []);
    } catch {
      return new Set();
    }
  });

  // Save expanded state to localStorage
  useEffect(() => {
    localStorage.setItem(storageKey, JSON.stringify([...expanded]));
  }, [expanded, storageKey]);

  // Build tree structure
  const tree = useMemo(() => buildTree(objects, sort), [objects, sort]);

  // Flatten tree for rendering
  const flatNodes = useMemo(() => flattenTree(tree, expanded), [tree, expanded]);

  // Toggle expand/collapse
  const toggleExpand = useCallback((objectId: string) => {
    setExpanded((prev) => {
      const next = new Set(prev);
      if (next.has(objectId)) {
        next.delete(objectId);
      } else {
        next.add(objectId);
      }
      return next;
    });
  }, []);

  // Get fields and options for the first class (for now)
  // TODO: Support per-class fields when class filtering is implemented
  const firstClass = crm.classes[0]?.id || "task";
  const fields = crm.fields[firstClass] || [];
  const options = crm.options[firstClass] || {};

  // Get visible fields from view's fields setting, or fall back to field's card property
  const viewFieldsList = viewFields?.split(",").filter(Boolean) || [];
  const showClass = viewFieldsList.includes("class");
  const fieldMap = new Map(fields.map((f) => [f.id, f]));
  const visibleFields = viewFieldsList
    .map((id) => fieldMap.get(id))
    .filter(Boolean) as typeof fields;

  // Build class map for looking up class names
  const classMap = useMemo(() => {
    const map: Record<string, string> = {};
    for (const c of crm.classes) {
      map[c.id] = c.name;
    }
    return map;
  }, [crm.classes]);

  // Build object map for looking up objects by ID
  const objectMap = useMemo(() => {
    const map: Record<string, CrmObject> = {};
    for (const obj of objects) {
      map[obj.id] = obj;
    }
    return map;
  }, [objects]);

  // Check if reparenting is allowed by hierarchy rules
  const isReparentAllowed = useCallback(
    (childId: string, parentId: string | null) => {
      const child = objectMap[childId];
      if (!child) return false;

      const allowedParents = crm.hierarchy[child.class] || [];
      if (parentId === null) {
        // Check if root is allowed (empty string in hierarchy)
        return allowedParents.includes("");
      }

      const parent = objectMap[parentId];
      if (!parent) return false;

      // Check if parent's class is allowed
      return allowedParents.includes(parent.class);
    },
    [objectMap, crm.hierarchy],
  );

  // FLIP animation: capture row positions before drop, animate after re-render
  const containerRef = useRef<HTMLDivElement>(null);
  const flipRef = useRef<Map<string, DOMRect>>(new Map());

  useLayoutEffect(() => {
    const prev = flipRef.current;
    if (!prev.size || !containerRef.current) return;

    const animations: HTMLElement[] = [];
    containerRef.current.querySelectorAll('[data-card-id]').forEach(row => {
      const id = row.getAttribute('data-card-id');
      if (!id) return;
      const oldRect = prev.get(id);
      if (!oldRect) return;
      const newRect = row.getBoundingClientRect();
      const dy = oldRect.top - newRect.top;
      if (Math.abs(dy) < 1) return;
      const el = row as HTMLElement;
      el.style.transition = 'none';
      el.style.transform = `translateY(${dy}px)`;
      animations.push(el);
    });

    // Only consume positions once rows have actually moved
    if (animations.length === 0) return;
    flipRef.current = new Map();

    document.body.getBoundingClientRect(); // force reflow
    for (const el of animations) {
      el.style.transition = 'transform 200ms ease-out';
      el.style.transform = '';
      el.addEventListener('transitionend', () => { el.style.transition = ''; }, { once: true });
    }
  });

  // Only allow reordering when sorting by rank
  const canReorder = sort?.field === "rank" || (!sort && true);

  // Drag state
  const [draggedId, setDraggedId] = useState<string | null>(null);
  const [dragOverId, setDragOverId] = useState<string | null>(null);
  const [dropPosition, setDropPosition] = useState<"before" | "after" | "on" | null>(null);

  const handleDragStart = useCallback((objectId: string) => {
    setDraggedId(objectId);
  }, []);

  const handleDragOver = useCallback(
    (objectId: string, position: "before" | "after" | "on") => {
      if (!draggedId || draggedId === objectId) return;

      // For "on" position (reparent), check if allowed
      if (position === "on") {
        if (!isReparentAllowed(draggedId, objectId)) return;
      }

      // For reorder positions, check if items share same parent and reordering is allowed
      if (position === "before" || position === "after") {
        if (!canReorder) return;
        const draggedObj = objectMap[draggedId];
        const targetObj = objectMap[objectId];
        if (!draggedObj || !targetObj) return;
        // Only allow reordering within same parent level
        if (draggedObj.parent !== targetObj.parent) return;
      }

      setDragOverId(objectId);
      setDropPosition(position);
    },
    [draggedId, isReparentAllowed, canReorder, objectMap],
  );


  const handleDragEnd = useCallback(() => {
    if (draggedId && dragOverId && draggedId !== dragOverId) {
      // Capture row positions for FLIP animation before mutation
      if (containerRef.current) {
        const positions = new Map<string, DOMRect>();
        containerRef.current.querySelectorAll('[data-card-id]').forEach(el => {
          positions.set(el.getAttribute('data-card-id')!, el.getBoundingClientRect());
        });
        flipRef.current = positions;
      }

      if (dropPosition === "on" && onReparent && isReparentAllowed(draggedId, dragOverId)) {
        // Reparent: make dragged item a child of target
        onReparent(draggedId, dragOverId);
      } else if ((dropPosition === "before" || dropPosition === "after") && onReorder && canReorder) {
        // Reorder within same parent
        const targetObj = objectMap[dragOverId];
        const draggedObj = objectMap[draggedId];
        if (targetObj && draggedObj && targetObj.parent === draggedObj.parent) {
          // Find siblings and calculate new rank
          const flatNode = flatNodes.find((fn) => fn.node.object.id === dragOverId);
          if (flatNode) {
            const { siblings } = flatNode;
            // Filter out the dragged item from siblings for rank calculation
            const siblingsWithoutDragged = siblings.filter((s) => s.id !== draggedId);
            // Find where target is in the filtered list
            const targetIndex = siblingsWithoutDragged.findIndex((s) => s.id === dragOverId);
            // Calculate insert index
            const insertIndex = dropPosition === "before" ? targetIndex : targetIndex + 1;
            const newRank = calculateRank(siblingsWithoutDragged, insertIndex);
            onReorder(draggedId, newRank);
          }
        }
      }
    }
    setDraggedId(null);
    setDragOverId(null);
    setDropPosition(null);
  }, [
    draggedId,
    dragOverId,
    dropPosition,
    onReparent,
    onReorder,
    isReparentAllowed,
    canReorder,
    objectMap,
    flatNodes,
  ]);

  if (objects.length === 0) {
    return (
      <EmptyState icon={Folder} title="Nothing found" className="py-12">
        {onCreateClick && (
          <Button variant="outline" size="sm" onClick={onCreateClick}>
            <Plus className="size-4 mr-1" />
            Create
          </Button>
        )}
      </EmptyState>
    );
  }

  return (
    <div ref={containerRef} className="border rounded-[10px] overflow-hidden bg-background relative">
      <table className="w-full border-collapse">
        <tbody className="divide-y divide-border">
          {flatNodes.map(({ node, hasChildren, isExpanded, anySiblingHasChildren }) => {
            const draggedObj = draggedId ? objectMap[draggedId] : null;
            const canReorderHere =
              canReorder && draggedObj && draggedObj.parent === node.object.parent && draggedId !== node.object.id;

            return (
              <TreeRow
                key={node.object.id}
                object={node.object}
                depth={node.depth}
                hasChildren={hasChildren}
                isExpanded={isExpanded}
                anySiblingHasChildren={anySiblingHasChildren}
                fields={visibleFields}
                options={options}
                peopleMap={peopleMap}
                classMap={classMap}
                titleFieldId={crm.classes.find((c) => c.id === node.object.class)?.title}
                showClass={showClass}
                isDragOver={dragOverId === node.object.id && dropPosition === "on"}
                isDragBefore={dragOverId === node.object.id && dropPosition === "before"}
                isDragAfter={dragOverId === node.object.id && dropPosition === "after"}
                canReorder={!!canReorderHere}
                canReparent={!!draggedId && draggedId !== node.object.id && isReparentAllowed(draggedId, node.object.id)}
                onToggleExpand={() => toggleExpand(node.object.id)}
                onClick={() => onCardClick(node.object)}
                onDragStart={() => handleDragStart(node.object.id)}
                onDragOver={handleDragOver}
                onDragEnd={handleDragEnd}
              />
            );
          })}
        </tbody>
      </table>
    </div>
  );
}
