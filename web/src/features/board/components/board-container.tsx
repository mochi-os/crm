// Mochi CRMs: Board container component
// Copyright Alistair Cunningham 2026

import { useMemo, useState, useEffect, useLayoutEffect, useCallback, useRef } from "react";
import { cn } from "@mochi/web";
import { BoardColumn, type BoardColumnRow } from "./board-column";
import type { CrmObject, CrmDetails, CrmClass, FieldOption, SortState } from "@/types";

// Check if objectId is a descendant of ancestorId
function isDescendantOf(objectId: string, ancestorId: string, objectMap: Record<string, CrmObject>): boolean {
  let current = objectMap[objectId]?.parent;
  while (current) {
    if (current === ancestorId) return true;
    current = objectMap[current]?.parent || "";
  }
  return false;
}

interface BoardContainerProps {
  crm: CrmDetails;
  objects: CrmObject[];
  statusField: string;
  rowField?: string;
  borderField?: string;
  viewFields?: string;
  viewClasses?: string[];
  sort?: SortState | null;
  peopleMap?: Record<string, string>;
  onCardClick?: (object: CrmObject) => void;
  onCardDoubleClick?: (object: CrmObject) => void;
  onCreateClick?: (statusId: string, rowId?: string) => void;
  onMoveObject?: (objectId: string, newStatus: string, newRank?: number, newRow?: string, scopeParent?: string, promote?: boolean) => void;
  onReparentObject?: (objectId: string, newParentId: string | null) => void;
  onRenameColumn?: (classId: string, fieldId: string, optionId: string, newName: string) => Promise<void>;
  onDeleteColumn?: (classId: string, fieldId: string, optionId: string) => Promise<void>;
  isReordering?: boolean;
  onReorderColumns?: (order: string[]) => void;
}

// Sort objects within a group by the active sort field
function sortObjects(objects: CrmObject[], sort?: SortState | null): CrmObject[] {
  const sortField = sort?.field || "rank";
  const sortDirection = sort?.direction || "asc";
  const multiplier = sortDirection === "asc" ? 1 : -1;

  return [...objects].sort((a, b) => {
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
  });
}

// Drag preview state: tracks where cards would be if dropped at current cursor position
export interface DragPreview {
  draggedId: string;
  sourceColumn: string;
  sourceRow: string;
  targetColumn: string;
  targetRow: string;
  targetIndex: number;
  mode: "between" | "on";
  dropOnCardId?: string;
  cardHeight: number;
  childReorder?: { parentId: string; rank: number };
}

export function BoardContainer({
  crm,
  objects,
  statusField,
  rowField,
  borderField,
  viewFields,
  viewClasses,
  sort,
  peopleMap,
  onCardClick,
  onCardDoubleClick,
  onCreateClick,
  onMoveObject,
  onReparentObject,
  onRenameColumn,
  onDeleteColumn,
  isReordering,
  onReorderColumns,
}: BoardContainerProps) {
  // Get the effective class — use the view's class filter if set, otherwise first class
  const defaultClass = useMemo(() => {
    if (viewClasses?.length) {
      return crm.classes.find((c) => c.id === viewClasses[0]) || crm.classes[0];
    }
    return crm.classes[0];
  }, [crm.classes, viewClasses]);
  const classFields = useMemo(() => defaultClass ? crm.fields[defaultClass.id] || [] : [], [defaultClass, crm.fields]);
  const classOptions = useMemo(() => defaultClass ? crm.options[defaultClass.id] || {} : {}, [defaultClass, crm.options]);

  // Parse view fields list
  const viewFieldsList = useMemo(
    () => (viewFields || "").split(",").filter(Boolean),
    [viewFields]
  );

  // Map view fields in order, looking up from class fields
  const visibleFields = useMemo(() => {
    const fieldMap = new Map(classFields.map((f) => [f.id, f]));
    return viewFieldsList.map((id) => fieldMap.get(id)).filter(Boolean) as typeof classFields;
  }, [classFields, viewFieldsList]);

  // Build a map of object id to object for quick parent lookups
  const objectMap = useMemo(() => {
    const map: Record<string, CrmObject> = {};
    for (const obj of objects) {
      map[obj.id] = obj;
    }
    return map;
  }, [objects]);

  // Build a class map for quick lookups
  const classMap = useMemo(() => {
    const map: Record<string, CrmClass> = {};
    for (const cls of crm.classes) {
      map[cls.id] = cls;
    }
    return map;
  }, [crm.classes]);

  // Build children-by-parent map for nested card rendering
  const childrenByParent = useMemo(() => {
    const map: Record<string, CrmObject[]> = {};
    for (const obj of objects) {
      if (obj.parent && objectMap[obj.parent]) {
        if (!map[obj.parent]) map[obj.parent] = [];
        map[obj.parent].push(obj);
      }
    }
    for (const key of Object.keys(map)) {
      map[key] = sortObjects(map[key], { field: "rank", direction: "asc" });
    }
    return map;
  }, [objects, objectMap]);

  // Get status options for columns
  const statusOptions = useMemo(() => {
    const opts = classOptions[statusField] || [];
    return [...opts].sort((a, b) => a.rank - b.rank);
  }, [classOptions, statusField]);

  // Get row options (for swimlanes)
  const rowOptions = useMemo(() => {
    if (!rowField) return [];
    const opts = classOptions[rowField] || [];
    return [...opts].sort((a, b) => a.rank - b.rank);
  }, [classOptions, rowField]);

  const hasRows = rowField && rowOptions.length > 0;

  // Measure board position to compute viewport-filling min-height dynamically.
  // Observes ancestor elements for resize so minHeight recalculates when
  // siblings like the view options bar appear or disappear.
  const boardRef = useRef<HTMLDivElement>(null);
  const [minHeight, setMinHeight] = useState("");

  useLayoutEffect(() => {
    const el = boardRef.current;
    if (!el) return;
    const update = () => {
      const top = Math.ceil(el.getBoundingClientRect().top);
      setMinHeight(`calc(100dvh - ${top}px)`);
    };
    update();
    const observer = new ResizeObserver(update);
    let ancestor = el.parentElement;
    while (ancestor) {
      observer.observe(ancestor);
      ancestor = ancestor.parentElement;
    }
    return () => observer.disconnect();
  }, []);

  // Drag preview state for real-time card reflow during drag
  const [dragPreview, setDragPreview] = useState<DragPreview | null>(null);
  const dragPreviewRef = useRef<DragPreview | null>(null);

  // FLIP animation: capture card positions before re-render, animate after
  const flipRef = useRef<Map<string, DOMRect>>(new Map());
  const lastDragPosRef = useRef<{ x: number; y: number }>({ x: 0, y: 0 });

  // Capture positions of all top-level cards for FLIP
  const capturePositions = useCallback(() => {
    if (!boardRef.current) return;
    const positions = new Map<string, DOMRect>();
    boardRef.current.querySelectorAll('[data-card-id]').forEach(el => {
      if (!el.parentElement?.closest('[data-card-id]')) {
        positions.set(el.getAttribute('data-card-id')!, el.getBoundingClientRect());
      }
    });
    flipRef.current = positions;
  }, []);

  // FLIP animation effect — runs after every render when positions are captured
  useLayoutEffect(() => {
    const prev = flipRef.current;
    if (!prev.size || !boardRef.current) return;

    const preview = dragPreviewRef.current;
    const animations: HTMLElement[] = [];
    boardRef.current.querySelectorAll('[data-card-id]').forEach(card => {
      if (card.parentElement?.closest('[data-card-id]')) return;
      const id = card.getAttribute('data-card-id');
      if (!id) return;
      // Skip the dragged card during preview — it's hidden
      if (preview && id === preview.draggedId) return;
      const oldRect = prev.get(id);
      if (!oldRect) return;
      const newRect = card.getBoundingClientRect();
      const dx = oldRect.left - newRect.left;
      const dy = oldRect.top - newRect.top;
      if (Math.abs(dx) < 1 && Math.abs(dy) < 1) return;
      const el = card as HTMLElement;
      el.style.transition = 'none';
      el.style.transform = `translate(${dx}px, ${dy}px)`;
      animations.push(el);
    });

    if (animations.length === 0) return;
    flipRef.current = new Map();

    document.body.getBoundingClientRect(); // force reflow
    for (const el of animations) {
      el.style.transition = 'transform 150ms ease-out';
      el.style.transform = '';
      el.addEventListener('transitionend', () => { el.style.transition = ''; }, { once: true });
    }
  });

  // Local reorder state
  const [reorderedColumns, setReorderedColumns] = useState<FieldOption[]>(statusOptions);
  const [draggedColumnId, setDraggedColumnId] = useState<string | null>(null);

  // Sync local reorder state when statusOptions changes or reordering mode starts/stops
  useEffect(() => {
    setReorderedColumns(statusOptions);
  }, [statusOptions, isReordering]);

  // Columns to render (use reordered if in reorder mode)
  const columnsToRender = isReordering ? reorderedColumns : statusOptions;

  // Group top-level objects by status (flat mode) and sort
  const objectsByStatus = useMemo(() => {
    const grouped: Record<string, CrmObject[]> = {};

    // Initialize all columns
    statusOptions.forEach((opt) => {
      grouped[opt.id] = [];
    });

    // Also add a column for items without status
    grouped[""] = [];

    // Group objects — skip nested children (they render inside parent cards)
    objects.forEach((obj) => {
      if (obj.parent && objectMap[obj.parent]) return;
      const status = obj.values[statusField] || "";
      if (grouped[status]) {
        grouped[status].push(obj);
      } else {
        grouped[""].push(obj);
      }
    });

    // Sort each column
    Object.keys(grouped).forEach((status) => {
      grouped[status] = sortObjects(grouped[status], sort);
    });

    return grouped;
  }, [objects, objectMap, statusOptions, statusField, sort]);

  // Group top-level objects by row then column (swimlane mode)
  const objectsByRowAndStatus = useMemo(() => {
    if (!hasRows) return {};

    const grouped: Record<string, Record<string, CrmObject[]>> = {};

    // Initialize all rows × columns
    for (const row of rowOptions) {
      grouped[row.id] = {};
      for (const col of statusOptions) {
        grouped[row.id][col.id] = [];
      }
      grouped[row.id][""] = [];
    }
    // "No row" bucket
    grouped[""] = {};
    for (const col of statusOptions) {
      grouped[""][col.id] = [];
    }
    grouped[""][""] = [];

    // Group objects — skip nested children
    objects.forEach((obj) => {
      if (obj.parent && objectMap[obj.parent]) return;
      const status = obj.values[statusField] || "";
      const row = obj.values[rowField!] || "";

      // Fall back to "" bucket if row/status value doesn't match any known option
      const targetRow = grouped[row] ? row : "";
      const targetStatus = grouped[targetRow][status] !== undefined ? status : "";
      grouped[targetRow][targetStatus].push(obj);
    });

    // Sort each cell
    Object.keys(grouped).forEach((rowId) => {
      Object.keys(grouped[rowId]).forEach((colId) => {
        grouped[rowId][colId] = sortObjects(grouped[rowId][colId], sort);
      });
    });

    return grouped;
  }, [objects, objectMap, statusOptions, rowOptions, statusField, rowField, hasRows, sort]);

  // Apply drag preview to get the card lists columns should render.
  // For same-column moves, keep the card in the list (renderCardsWithGap will handle it).
  // For cross-column moves, remove the card from the source column.
  const applyPreviewToList = useCallback((list: CrmObject[]): CrmObject[] => {
    if (!dragPreview || dragPreview.mode === "on" || dragPreview.childReorder) return list;
    // Same-column: keep the card in the list so it stays in the DOM for calculateDropIndex to skip
    if (dragPreview.sourceColumn === dragPreview.targetColumn) return list;
    // Cross-column: remove from source
    return list.filter(o => o.id !== dragPreview.draggedId);
  }, [dragPreview]);

  // Handle drag preview updates from columns
  const handleDragPreview = useCallback((preview: DragPreview | null) => {
    if (!preview) {
      dragPreviewRef.current = null;
      setDragPreview(null);
      return;
    }
    // Only update if something actually changed
    const prev = dragPreviewRef.current;
    if (prev &&
        prev.targetColumn === preview.targetColumn &&
        prev.targetRow === preview.targetRow &&
        prev.targetIndex === preview.targetIndex &&
        prev.mode === preview.mode &&
        prev.dropOnCardId === preview.dropOnCardId &&
        prev.childReorder?.parentId === preview.childReorder?.parentId &&
        prev.childReorder?.rank === preview.childReorder?.rank) {
      return;
    }
    capturePositions();
    dragPreviewRef.current = preview;
    setDragPreview(preview);
  }, [capturePositions]);

  // Clear preview when server response arrives (not on the optimistic update).
  // The optimistic update fires first (changes objects), then the server response
  // fires second (changes objects again via query invalidation). We skip the first
  // change and clear on the second so the gap stays visible until real data arrives.
  const prevObjectsRef = useRef(objects);
  const objectsChangeCount = useRef(0);
  useEffect(() => {
    if (objects !== prevObjectsRef.current) {
      if (dragPreview) {
        objectsChangeCount.current++;
        if (objectsChangeCount.current >= 2) {
          handleDragPreview(null);
          objectsChangeCount.current = 0;
        }
      }
    }
    prevObjectsRef.current = objects;
  }, [objects, dragPreview, handleDragPreview]);
  // Reset counter when preview starts
  useEffect(() => {
    if (dragPreview) objectsChangeCount.current = 0;
  }, [!!dragPreview]);

  // Count descendants of a card that have the same status value (the server
  // includes these in its scope but the board only shows top-level cards)
  const countDescendantsInStatus = useCallback((parentId: string, statusValue: string): number => {
    const children = childrenByParent[parentId] || [];
    let count = 0;
    for (const child of children) {
      if ((child.values[statusField] || "") === statusValue) count++;
      count += countDescendantsInStatus(child.id, statusValue);
    }
    return count;
  }, [childrenByParent, statusField]);

  // Handle drop events — distinguishes between-cards, drop-on-card, and sibling reorder
  const handleDrop = (onMoveObject || onReparentObject) ? (
    objectId: string, columnId: string, newRank?: number, rowId?: string, dropOnCardId?: string, reorderParentId?: string, reorderRank?: number
  ) => {
    const draggedObj = objectMap[objectId];
    if (!draggedObj) return;

    // Reorder child among siblings
    if (reorderParentId && reorderRank !== undefined) {
      if (draggedObj.parent === reorderParentId) {
        onMoveObject?.(objectId, "", reorderRank, undefined, reorderParentId);
      } else if (onReparentObject) {
        const parentObj = objectMap[reorderParentId];
        if (!parentObj) return;
        const allowedParents = crm.hierarchy[draggedObj.class];
        if (!allowedParents || !allowedParents.includes(parentObj.class)) return;
        if (isDescendantOf(reorderParentId, objectId, objectMap)) return;
        onReparentObject(objectId, reorderParentId);
      }
      return;
    }

    // Drop on a card → reparent
    if (dropOnCardId && onReparentObject) {
      if (dropOnCardId === objectId) return;
      if (isDescendantOf(dropOnCardId, objectId, objectMap)) return;
      const targetObj = objectMap[dropOnCardId];
      if (!targetObj) return;
      const allowedParents = crm.hierarchy[draggedObj.class];
      if (!allowedParents || !allowedParents.includes(targetObj.class)) return;
      onReparentObject(objectId, dropOnCardId);
      return;
    }

    // Drop between cards — check if child needs promotion
    if (draggedObj.parent && objectMap[draggedObj.parent]) {
      const parent = objectMap[draggedObj.parent];
      const parentStatus = parent?.values[statusField] || "";
      const parentRow = rowField ? (parent?.values[rowField] || "") : undefined;
      const columnChanged = columnId !== parentStatus;
      const rowChanged = rowId !== undefined && rowId !== parentRow;
      if (columnChanged || rowChanged) {
        const allowedParents = crm.hierarchy[draggedObj.class];
        if (!allowedParents || !allowedParents.includes("")) return;
        onMoveObject?.(objectId, columnId, newRank, rowId, undefined, true);
        return;
      }
    }

    // Adjust rank to account for child objects that the server includes in its
    // scope but the board displays nested inside their parent cards. The server
    // renumbers ALL objects with the matching status, not just top-level ones,
    // and children can have ranks anywhere in the flat list (not necessarily
    // adjacent to their parent). Build the full flat list, find where the
    // top-level insertion point falls, and count preceding non-top-level objects.
    let adjustedRank = newRank;
    if (newRank) {
      const topLevel = (objectsByStatus[columnId] || []).filter(o => o.id !== objectId);
      // Build flat list of all objects in scope (same status), sorted by rank
      const allInScope = objects
        .filter(o => o.id !== objectId && (o.values[statusField] || "") === columnId)
        .sort((a, b) => (a.rank || 0) - (b.rank || 0));
      const topLevelIds = new Set(topLevel.map(o => o.id));
      // Walk the flat list until we reach the newRank-th top-level card,
      // then insert just before it. flatPos counts items we've passed.
      let topCount = 0;
      let flatPos = 0;
      for (const obj of allInScope) {
        if (topLevelIds.has(obj.id)) {
          topCount++;
          if (topCount >= newRank) break;
        }
        flatPos++;
      }
      adjustedRank = flatPos + 1;
    }

    onMoveObject?.(objectId, columnId, adjustedRank, rowId);
  } : undefined;

  // Auto-scroll the nearest scrollable ancestor when dragging near its edges
  const scrollRafRef = useRef(0);
  const scrollVelocityRef = useRef({ x: 0, y: 0 });
  const scrollContainerRef = useRef<Element | null>(null);

  useEffect(() => {
    // Find the scrollable ancestor (the SidebarInset with overflow-auto)
    const findScrollParent = (el: Element | null): Element | null => {
      while (el) {
        const style = getComputedStyle(el);
        if (style.overflow === "auto" || style.overflow === "scroll" ||
            style.overflowX === "auto" || style.overflowX === "scroll" ||
            style.overflowY === "auto" || style.overflowY === "scroll") {
          return el;
        }
        el = el.parentElement;
      }
      return null;
    };

    if (boardRef.current) {
      scrollContainerRef.current = findScrollParent(boardRef.current);
    }
  }, []);

  useEffect(() => {
    const edgeSize = 60;
    const maxSpeed = 20;

    const onDragOver = (e: DragEvent) => {
      lastDragPosRef.current = { x: e.clientX, y: e.clientY };

      const container = scrollContainerRef.current;
      if (!container) return;

      const rect = container.getBoundingClientRect();
      const { clientX, clientY } = e;
      let vx = 0;
      let vy = 0;

      // Horizontal edges relative to scroll container
      const distLeft = clientX - rect.left;
      const distRight = rect.right - clientX;
      if (distLeft < edgeSize && distLeft >= 0) {
        vx = -maxSpeed * (1 - distLeft / edgeSize);
      } else if (distRight < edgeSize && distRight >= 0) {
        vx = maxSpeed * (1 - distRight / edgeSize);
      }

      // Vertical edges relative to scroll container
      const distTop = clientY - rect.top;
      const distBottom = rect.bottom - clientY;
      if (distTop < edgeSize && distTop >= 0) {
        vy = -maxSpeed * (1 - distTop / edgeSize);
      } else if (distBottom < edgeSize && distBottom >= 0) {
        vy = maxSpeed * (1 - distBottom / edgeSize);
      }

      scrollVelocityRef.current = { x: vx, y: vy };

      if ((vx !== 0 || vy !== 0) && !scrollRafRef.current) {
        const tick = () => {
          const { x, y } = scrollVelocityRef.current;
          if (x === 0 && y === 0) {
            scrollRafRef.current = 0;
            return;
          }
          container.scrollBy(x, y);
          scrollRafRef.current = requestAnimationFrame(tick);
        };
        scrollRafRef.current = requestAnimationFrame(tick);
      }
    };

    const onDragEnd = () => {
      scrollVelocityRef.current = { x: 0, y: 0 };
      if (scrollRafRef.current) {
        cancelAnimationFrame(scrollRafRef.current);
        scrollRafRef.current = 0;
      }
    };

    document.addEventListener("dragover", onDragOver);
    document.addEventListener("dragend", onDragEnd);
    document.addEventListener("drop", onDragEnd);
    return () => {
      document.removeEventListener("dragover", onDragOver);
      document.removeEventListener("dragend", onDragEnd);
      document.removeEventListener("drop", onDragEnd);
      onDragEnd();
    };
  }, []);

  // Create invisible drag image
  const emptyDragImage = useRef<HTMLDivElement | null>(null);
  useEffect(() => {
    if (!emptyDragImage.current) {
      const div = document.createElement("div");
      div.style.width = "1px";
      div.style.height = "1px";
      div.style.position = "fixed";
      div.style.top = "-1000px";
      document.body.appendChild(div);
      emptyDragImage.current = div;
    }
    return () => {
      if (emptyDragImage.current) {
        document.body.removeChild(emptyDragImage.current);
        emptyDragImage.current = null;
      }
    };
  }, []);

  // Column drag handlers
  const handleColumnDragStart = useCallback((e: React.DragEvent, columnId: string) => {
    setDraggedColumnId(columnId);
    e.dataTransfer.effectAllowed = "move";
    e.dataTransfer.setData("text/plain", columnId);
    // Use invisible drag image so only our styled column shows
    if (emptyDragImage.current) {
      e.dataTransfer.setDragImage(emptyDragImage.current, 0, 0);
    }
  }, []);

  const handleColumnDragOver = useCallback((e: React.DragEvent, targetColumnId: string) => {
    e.preventDefault();
    if (!draggedColumnId || draggedColumnId === targetColumnId) return;

    setReorderedColumns((prev) => {
      const draggedIndex = prev.findIndex((c) => c.id === draggedColumnId);
      const targetIndex = prev.findIndex((c) => c.id === targetColumnId);
      if (draggedIndex === -1 || targetIndex === -1) return prev;

      const newOrder = [...prev];
      const [removed] = newOrder.splice(draggedIndex, 1);
      newOrder.splice(targetIndex, 0, removed);
      return newOrder;
    });
  }, [draggedColumnId]);

  const handleColumnDragEnd = useCallback(() => {
    if (draggedColumnId && isReordering) {
      onReorderColumns?.(reorderedColumns.map((c) => c.id));
    }
    setDraggedColumnId(null);
  }, [draggedColumnId, isReordering, reorderedColumns, onReorderColumns]);

  // Render a single column with its reorder wrapper
  const renderColumn = (
    status: FieldOption,
    columnObjects: CrmObject[],
    rows?: BoardColumnRow[],
    gridCol?: number,
    gridRowSpan?: number,
    onCreateInRow?: (rowId: string) => void,
  ) => {
    const isDragging = draggedColumnId === status.id;
    // Apply preview filtering to card lists
    const previewObjects = applyPreviewToList(columnObjects);
    const previewRows = rows?.map(r => ({
      ...r,
      objects: applyPreviewToList(r.objects),
    }));
    return (
      <div
        key={status.id}
        draggable={isReordering}
        onDragStart={isReordering ? (e) => handleColumnDragStart(e, status.id) : undefined}
        onDragOver={isReordering ? (e) => handleColumnDragOver(e, status.id) : undefined}
        onDragEnd={isReordering ? handleColumnDragEnd : undefined}
        className={cn(
          isReordering && "cursor-grab active:cursor-grabbing transition-transform duration-200 ease-out",
          isDragging && "opacity-90 scale-[1.02] shadow-xl z-10 rotate-1"
        )}
        style={gridCol ? {
          gridColumn: gridCol,
          gridRow: `1 / span ${gridRowSpan}`,
          display: 'grid',
          gridTemplateRows: 'subgrid',
        } : undefined}
      >
        <BoardColumn
          id={status.id}
          name={status.name}
          colour={status.colour}
          objects={previewObjects}
          fields={visibleFields}
          options={classOptions}
          objectMap={objectMap}
          allFields={crm.fields}
          allObjects={objects}
          statusField={statusField}
          rowField={rowField}
          borderField={borderField}
          classMap={classMap}
          peopleMap={peopleMap}
          childrenByParent={childrenByParent}
          hierarchy={crm.hierarchy}
          onCardClick={isReordering ? undefined : onCardClick}
          onCardDoubleClick={isReordering ? undefined : onCardDoubleClick}
          onCreateClick={isReordering ? undefined : () => onCreateClick?.(status.id)}
          onCreateInRow={isReordering ? undefined : onCreateInRow}
          onDrop={isReordering ? undefined : handleDrop}
          onDragPreview={isReordering ? undefined : handleDragPreview}
          dragPreview={isReordering ? undefined : dragPreview}
          onRenameColumn={
            !isReordering && onRenameColumn && defaultClass
              ? (newName: string) => onRenameColumn(defaultClass.id, statusField, status.id, newName)
              : undefined
          }
          onDeleteColumn={
            !isReordering && onDeleteColumn && defaultClass
              ? () => onDeleteColumn(defaultClass.id, statusField, status.id)
              : undefined
          }
          isReordering={isReordering}
          isDragging={isDragging}
          rows={previewRows}
        />
      </div>
    );
  };

  // Swimlane layout (when rowField is active)
  if (hasRows) {
    // Check if there are any objects without a row value
    const hasNoRowObjects = Object.values(objectsByRowAndStatus[""] || {}).some(
      (arr) => arr.length > 0
    );

    // Build row metadata for swimlane columns
    const swimlaneRows: { id: string; label: string; colour?: string }[] = [
      ...rowOptions.map((r) => ({ id: r.id, label: r.name, colour: r.colour })),
      ...(hasNoRowObjects ? [{ id: "", label: "[not set]" }] : []),
    ];

    // Check if any row has objects without a status
    const hasNoStatusSwimlane = !isReordering && swimlaneRows.some(
      (row) => (objectsByRowAndStatus[row.id]?.[""]?.length || 0) > 0
    );

    const totalCols = columnsToRender.length + (hasNoStatusSwimlane ? 1 : 0);

    return (
      <div
        ref={boardRef}
        className="grid pb-2 gap-x-4"
        style={{
          minHeight,
          gridTemplateColumns: `max-content repeat(${totalCols}, 18rem)`,
          gridTemplateRows: `auto repeat(${swimlaneRows.length}, 1fr)`,
        }}
      >
        {/* Row indicators in left column */}
        {swimlaneRows.map((row, r) => (
          <div
            key={`label-${row.id}`}
            className={cn(
              "flex items-start gap-2 pt-2 pr-3",
              r < swimlaneRows.length - 1 && "border-b"
            )}
            style={{ gridColumn: 1, gridRow: r + 2 }}
          >
            {row.colour && (
              <div
                className="w-2.5 h-2.5 rounded-full shrink-0 mt-0.5"
                style={{ backgroundColor: row.colour }}
              />
            )}
            <span className="text-xs text-muted-foreground font-medium whitespace-nowrap">
              {row.label}
            </span>
          </div>
        ))}

        {/* Board columns */}
        {columnsToRender.map((status, c) =>
          renderColumn(
            status,
            [],
            swimlaneRows.map((row) => ({
              id: row.id,
              label: row.label,
              colour: row.colour,
              objects: objectsByRowAndStatus[row.id]?.[status.id] || [],
            })),
            c + 2,
            swimlaneRows.length + 1,
            onCreateClick ? (rowId: string) => onCreateClick(status.id, rowId) : undefined,
          )
        )}

        {/* Column for items without status */}
        {hasNoStatusSwimlane && (
          <div
            style={{
              gridColumn: columnsToRender.length + 2,
              gridRow: `1 / span ${swimlaneRows.length + 1}`,
              display: 'grid',
              gridTemplateRows: 'subgrid',
            }}
          >
            <BoardColumn
              id=""
              name="No status"
              objects={[]}
              fields={visibleFields}
              options={classOptions}
              objectMap={objectMap}
              allFields={crm.fields}
              allObjects={objects}
              statusField={statusField}
              rowField={rowField}
              borderField={borderField}
              classMap={classMap}
              peopleMap={peopleMap}
              childrenByParent={childrenByParent}
              hierarchy={crm.hierarchy}
              onCardClick={onCardClick}
              onCardDoubleClick={onCardDoubleClick}
              onDrop={isReordering ? undefined : handleDrop}
              onDragPreview={handleDragPreview}
              dragPreview={dragPreview}
              rows={swimlaneRows.map((row) => ({
                id: row.id,
                label: row.label,
                colour: row.colour,
                objects: applyPreviewToList(objectsByRowAndStatus[row.id]?.[""] || []),
              }))}
            />
          </div>
        )}
      </div>
    );
  }

  // Flat layout (no row field — existing behavior)
  return (
    <div ref={boardRef} className="flex gap-4 pb-2" style={{ minHeight }}>
      {columnsToRender.map((status) =>
        renderColumn(status, objectsByStatus[status.id] || [])
      )}

      {/* Column for items without status */}
      {!isReordering && objectsByStatus[""]?.length > 0 && (
        <BoardColumn
          id=""
          name="No status"
          objects={applyPreviewToList(objectsByStatus[""])}
          fields={visibleFields}
          options={classOptions}
          objectMap={objectMap}
          allFields={crm.fields}
          allObjects={objects}
          statusField={statusField}
          rowField={rowField}
          borderField={borderField}
          classMap={classMap}
          peopleMap={peopleMap}
          childrenByParent={childrenByParent}
          hierarchy={crm.hierarchy}
          onCardClick={onCardClick}
          onCardDoubleClick={onCardDoubleClick}
          onDrop={handleDrop}
          onDragPreview={handleDragPreview}
          dragPreview={dragPreview}
        />
      )}
    </div>
  );
}
