// Mochi CRMs: Board column component
// Copyright Alistair Cunningham 2026

import { useState, useRef, useEffect, useCallback } from "react";
import { createPortal } from "react-dom";
import {
  cn,
  ConfirmDialog,
  ResponsiveDialog,
  ResponsiveDialogContent,
  ResponsiveDialogDescription,
  ResponsiveDialogHeader,
  ResponsiveDialogTitle,
  ResponsiveDialogFooter,
  Button,
  Input,
  Label,
  DropdownMenu,
  DropdownMenuContent,
  DropdownMenuItem,
  DropdownMenuTrigger,
  Tooltip,
  TooltipContent,
  TooltipProvider,
  TooltipTrigger,
} from "@mochi/web";
import { Inbox, MoreHorizontal, Pencil, Plus, Trash2 } from "lucide-react";
import { BoardCard } from "./board-card";
import type { DragPreview } from "./board-container";
import type { CrmObject, CrmField, CrmClass, FieldOption } from "@/types";

export interface BoardColumnRow {
  id: string;
  label: string;
  colour?: string;
  objects: CrmObject[];
}

interface BoardColumnProps {
  id: string;
  name: string;
  colour?: string;
  crmId?: string;
  objects: CrmObject[];
  fields: CrmField[];
  options: Record<string, FieldOption[]>;
  objectMap: Record<string, CrmObject>;
  allFields?: Record<string, CrmField[]>;
  allObjects?: CrmObject[];
  statusField?: string;
  rowField?: string;
  borderField?: string;
  classMap?: Record<string, CrmClass>;
  peopleMap?: Record<string, string>;
  childrenByParent?: Record<string, CrmObject[]>;
  hierarchy?: Record<string, string[]>;
  onCardClick?: (object: CrmObject) => void;
  onCardDoubleClick?: (object: CrmObject) => void;
  onCreateClick?: () => void;
  onCreateInRow?: (rowId: string) => void;
  onDrop?: (objectId: string, columnId: string, newRank?: number, rowId?: string, dropOnCardId?: string, reorderParentId?: string, reorderRank?: number) => void;
  onDragPreview?: (preview: DragPreview | null) => void;
  dragPreview?: DragPreview | null;
  onRenameColumn?: (newName: string) => Promise<void>;
  onDeleteColumn?: () => Promise<void>;
  isReordering?: boolean;
  isDragging?: boolean;
  hideHeader?: boolean;
  rows?: BoardColumnRow[];
  preview?: boolean;
}

export function BoardColumn({
  id,
  name,
  colour,
  crmId,
  objects,
  fields,
  options,
  objectMap,
  allFields,
  allObjects,
  statusField,
  rowField,
  borderField,
  classMap,
  peopleMap,
  childrenByParent,
  hierarchy,
  onCardClick,
  onCardDoubleClick,
  onCreateClick,
  onCreateInRow,
  onDrop,
  onDragPreview,
  dragPreview,
  onRenameColumn,
  onDeleteColumn,
  isReordering,
  isDragging,
  hideHeader,
  rows,
  preview,
}: BoardColumnProps) {
  const [showRenameDialog, setShowRenameDialog] = useState(false);
  const [newName, setNewName] = useState(name);
  const [isRenaming, setIsRenaming] = useState(false);
  const [showDeleteDialog, setShowDeleteDialog] = useState(false);
  const [isDeleting, setIsDeleting] = useState(false);

  // Total object count across rows (or flat objects)
  const totalCount = rows ? rows.reduce((sum, r) => sum + r.objects.length, 0) : objects.length;

  // Drag state managed via refs + direct DOM manipulation to avoid re-renders
  const columnRef = useRef<HTMLDivElement>(null);
  const cardsContainerRef = useRef<HTMLDivElement>(null);
  const dropIndexRef = useRef(0);
  const dropRowRef = useRef("");
  const rowsRef = useRef(rows);
  rowsRef.current = rows;
  const isDragOverRef = useRef(false);
  const safetyTimeoutRef = useRef<ReturnType<typeof setTimeout>>(undefined);
  const indicatorRef = useRef<HTMLDivElement>(null);
  const dropModeRef = useRef<"between" | "on">("between");
  const dropTargetCardRef = useRef<string>("");
  const childReorderRef = useRef<{ parentId: string; rank: number } | null>(null);
  const objectMapRef = useRef(objectMap);
  objectMapRef.current = objectMap;
  const hierarchyRef = useRef(hierarchy);
  hierarchyRef.current = hierarchy;
  const dragSourceRef = useRef<{ id: string; column: string; row: string; height: number } | null>(null);
  const onDragPreviewRef = useRef(onDragPreview);
  onDragPreviewRef.current = onDragPreview;

  useEffect(() => {
    // Clear preview on dragend (cancelled drag, escape key, etc.)
    const onDragEnd = () => {
      dragSourceRef.current = null;
      onDragPreviewRef.current?.(null);
    };
    document.addEventListener("dragend", onDragEnd);
    return () => {
      clearTimeout(safetyTimeoutRef.current);
      document.removeEventListener("dragend", onDragEnd);
    };
  }, []);

  // Clear all drop-target highlights from card elements
  const clearDropTargetHighlights = useCallback(() => {
    columnRef.current?.querySelectorAll("[data-drop-target]").forEach((el) => {
      el.removeAttribute("data-drop-target");
    });
  }, []);

  const clearDragState = useCallback(() => {
    isDragOverRef.current = false;
    dropModeRef.current = "between";
    dropTargetCardRef.current = "";
    childReorderRef.current = null;
    dragSourceRef.current = null;
    columnRef.current?.removeAttribute("data-drag-over");
    if (indicatorRef.current) indicatorRef.current.style.opacity = "0";
    clearDropTargetHighlights();
    clearTimeout(safetyTimeoutRef.current);
  }, [clearDropTargetHighlights]);

  const handleDragEnter = useCallback((e: React.DragEvent) => {
    if (isReordering) return;
    e.preventDefault();
  }, [isReordering]);

  const handleDragOver = useCallback((e: React.DragEvent) => {
    if (isReordering) return;
    e.preventDefault();
    e.dataTransfer.dropEffect = "move";

    // Show column highlight via data attribute (CSS handles styling)
    if (!isDragOverRef.current) {
      isDragOverRef.current = true;
      columnRef.current?.setAttribute("data-drag-over", "");
    }

    // Safety net: clear if dragover stops firing
    clearTimeout(safetyTimeoutRef.current);
    safetyTimeoutRef.current = setTimeout(clearDragState, 500);

    const mouseY = e.clientY;
    const om = objectMapRef.current;
    const hr = hierarchyRef.current;
    let draggedId = "";
    let draggedClass = "";
    for (const t of e.dataTransfer.types) {
      if (t.startsWith("application/x-mochi-class-")) draggedClass = t.slice(26);
      else if (t.startsWith("application/x-mochi-id-")) draggedId = t.slice(23);
    }
    const draggedObj = draggedId ? om[draggedId] : undefined;

    // Capture drag source info on first dragover if not yet set
    if (draggedId && !dragSourceRef.current) {
      const draggedObjData = om[draggedId];
      if (draggedObjData) {
        const sourceStatus = draggedObjData.values[statusField || ""] || "";
        const sourceRow = rowField ? (draggedObjData.values[rowField] || "") : "";
        // Measure card height from the DOM
        const cardEl = columnRef.current?.querySelector(`[data-card-id="${CSS.escape(draggedId)}"]`) ||
          document.querySelector(`[data-card-id="${CSS.escape(draggedId)}"]`);
        const height = cardEl ? cardEl.getBoundingClientRect().height : 60;
        dragSourceRef.current = { id: draggedId, column: sourceStatus, row: sourceRow, height };
      }
    }

    const canParent = (parentClass: string) => {
      if (!draggedClass || !hr) return true;
      return hr[draggedClass]?.includes(parentClass) ?? true;
    };
    const isAncestor = (objId: string, ancestorId: string) => {
      let cur = om[objId]?.parent;
      while (cur) {
        if (cur === ancestorId) return true;
        cur = om[cur]?.parent || "";
      }
      return false;
    };

    // Drop detection: find deepest card under cursor
    let dropOnEl: Element | null = null;
    let dropOnId = "";
    let siblingReorder: { parentId: string; rank: number; index: number; container: Element; siblings: NodeListOf<Element> } | null = null;

    const targetEl = (e.target as HTMLElement).closest?.("[data-card-id]");
    if (targetEl) {
      const parentCardEl = targetEl.parentElement?.closest("[data-card-id]");
      const rect = targetEl.getBoundingClientRect();
      const edgeZone = parentCardEl
        ? Math.min(rect.height * 0.35, 20)
        : Math.min(rect.height * 0.2, 12);
      const distFromTop = mouseY - rect.top;
      const distFromBottom = rect.bottom - mouseY;

      if (distFromTop > edgeZone && distFromBottom > edgeZone) {
        const cardId = targetEl.getAttribute("data-card-id") || "";
        const cardObj = om[cardId];
        if (cardId && cardId !== draggedId && cardObj &&
          canParent(cardObj.class) &&
          (!draggedId || !isAncestor(cardId, draggedId))) {
          dropOnEl = targetEl;
          dropOnId = cardId;
        }
      } else {
        if (parentCardEl) {
          const parentId = parentCardEl.getAttribute("data-card-id") || "";
          const parentObj = om[parentId];
          const isAlreadySibling = draggedObj?.parent === parentId;
          if (isAlreadySibling || (parentObj && canParent(parentObj.class) && (!draggedId || !isAncestor(parentId, draggedId)))) {
            const sibContainer = targetEl.parentElement!;
            const siblings = sibContainer.querySelectorAll(":scope > [data-card-id]");
            let sibIndex = siblings.length;
            for (let i = 0; i < siblings.length; i++) {
              const sibRect = siblings[i].getBoundingClientRect();
              if (mouseY < sibRect.top + sibRect.height / 2) {
                sibIndex = i;
                break;
              }
            }
            siblingReorder = { parentId, rank: sibIndex + 1, container: sibContainer, siblings, index: sibIndex };
          }
        }
      }
    }

    // Calculate drop index for top-level between mode
    const calculateDropIndex = (cards: NodeListOf<Element>) => {
      let index = 0;
      for (let i = 0; i < cards.length; i++) {
        if (cards[i].getAttribute("data-card-id") === draggedId) continue;
        const cardRect = cards[i].getBoundingClientRect();
        if (mouseY < cardRect.top + cardRect.height / 2) {
          return index;
        }
        index++;
      }
      return index;
    };

    if (rowsRef.current && columnRef.current) {
      const sections = columnRef.current.querySelectorAll("[data-row-id]");
      for (const section of sections) {
        const rect = section.getBoundingClientRect();
        if (mouseY >= rect.top && mouseY <= rect.bottom) {
          dropRowRef.current = section.getAttribute("data-row-id") || "";
          const cards = section.querySelectorAll(":scope > [data-card-id]");
          dropIndexRef.current = calculateDropIndex(cards);
          break;
        }
      }
    } else if (cardsContainerRef.current) {
      const cards = cardsContainerRef.current.querySelectorAll(":scope > [data-card-id]");
      dropIndexRef.current = calculateDropIndex(cards);
    }

    // Visual feedback
    clearDropTargetHighlights();

    const source = dragSourceRef.current;

    if (dropOnEl && dropOnId) {
      dropModeRef.current = "on";
      dropTargetCardRef.current = dropOnId;
      childReorderRef.current = null;
      dropOnEl.setAttribute("data-drop-target", "");
      if (indicatorRef.current) indicatorRef.current.style.opacity = "0";
      // Send preview for drop-on-card mode
      if (onDragPreviewRef.current && source) {
        onDragPreviewRef.current({
          draggedId,
          sourceColumn: source.column,
          sourceRow: source.row,
          targetColumn: id,
          targetRow: dropRowRef.current,
          targetIndex: dropIndexRef.current,
          mode: "on",
          dropOnCardId: dropOnId,
          cardHeight: source.height,
        });
      }
    } else if (siblingReorder) {
      dropModeRef.current = "between";
      dropTargetCardRef.current = "";
      childReorderRef.current = { parentId: siblingReorder.parentId, rank: siblingReorder.rank };

      // Show line indicator between siblings (keep for nested reorder)
      if (indicatorRef.current) {
        const containerRect = siblingReorder.container.getBoundingClientRect();
        const idx = siblingReorder.index;
        let top: number;
        if (idx < siblingReorder.siblings.length) {
          top = siblingReorder.siblings[idx].getBoundingClientRect().top;
        } else {
          top = siblingReorder.siblings[siblingReorder.siblings.length - 1].getBoundingClientRect().bottom + 4;
        }
        indicatorRef.current.style.top = `${top}px`;
        indicatorRef.current.style.left = `${containerRect.left + 4}px`;
        indicatorRef.current.style.width = `${containerRect.width - 8}px`;
        indicatorRef.current.style.opacity = "1";
      }
      // Send preview for sibling reorder
      if (onDragPreviewRef.current && source) {
        onDragPreviewRef.current({
          draggedId,
          sourceColumn: source.column,
          sourceRow: source.row,
          targetColumn: id,
          targetRow: dropRowRef.current,
          targetIndex: dropIndexRef.current,
          mode: "between",
          cardHeight: source.height,
          childReorder: { parentId: siblingReorder.parentId, rank: siblingReorder.rank },
        });
      }
    } else {
      dropModeRef.current = "between";
      dropTargetCardRef.current = "";
      childReorderRef.current = null;

      const isChild = draggedObj?.parent && om[draggedObj.parent];
      const canDropBetween = !isChild || canParent("");

      if (!canDropBetween) {
        if (indicatorRef.current) indicatorRef.current.style.opacity = "0";
      } else {
        // Hide the line indicator — the gap placeholder provides visual feedback
        if (indicatorRef.current) indicatorRef.current.style.opacity = "0";
        // Send preview for between-cards mode
        if (onDragPreviewRef.current && source) {
          onDragPreviewRef.current({
            draggedId,
            sourceColumn: source.column,
            sourceRow: source.row,
            targetColumn: id,
            targetRow: dropRowRef.current,
            targetIndex: dropIndexRef.current,
            mode: "between",
            cardHeight: source.height,
          });
        }
      }
    }
  }, [isReordering, id, statusField, rowField, clearDragState, clearDropTargetHighlights]);

  const handleDragLeave = useCallback((e: React.DragEvent) => {
    if (isReordering) return;
    const relatedTarget = e.relatedTarget as Node | null;
    // Only clear if relatedTarget is definitively outside the column.
    // Null relatedTarget (common when crossing nested element boundaries)
    // is handled by the safety timeout instead.
    if (relatedTarget && !columnRef.current?.contains(relatedTarget)) {
      clearDragState();
    }
  }, [isReordering, clearDragState]);

  const handleDrop = useCallback((e: React.DragEvent) => {
    e.preventDefault();
    const rank = dropIndexRef.current + 1;
    const rowId = rowsRef.current ? dropRowRef.current : undefined;
    const dropOnCardId = dropModeRef.current === "on" ? dropTargetCardRef.current : undefined;
    const childReorder = childReorderRef.current;
    clearDragState();
    const objectId = e.dataTransfer.getData("text/plain");
    if (objectId && onDrop) {
      onDrop(objectId, id, rank, rowId, dropOnCardId, childReorder?.parentId, childReorder?.rank);
    }
    onDragPreviewRef.current?.(null);
  }, [id, onDrop, clearDragState]);

  // Render a gap placeholder where the dragged card will land.
  // For same-column moves, include data-card-id so calculateDropIndex skips it.
  const renderGap = (height: number, cardId?: string) => (
    <div
      key="__drag-gap__"
      data-card-id={cardId}
      className="rounded-lg border-2 border-dashed border-primary/30 bg-primary/5 transition-all duration-150"
      style={{ height }}
    />
  );

  // Render a single card with its children
  const renderCard = (object: CrmObject) => (
    <div key={object.id} data-card-id={object.id} className="rounded-lg transition-shadow data-drop-target:ring-2 data-drop-target:ring-primary">
      <BoardCard
        crmId={crmId}
        object={object}
        fields={fields}
        options={options}
        objectMap={objectMap}
        allFields={allFields}
        allObjects={allObjects}
        statusField={statusField}
        rowField={rowField}
        borderField={borderField}
        classMap={classMap}
        peopleMap={peopleMap}
        draggable={!!onDrop}
        onClick={() => onCardClick?.(object)}
        onDoubleClick={onCardDoubleClick ? () => onCardDoubleClick(object) : undefined}
        children={childrenByParent?.[object.id] || []}
        childrenByParent={childrenByParent}
        hierarchy={hierarchy}
        onChildClick={onCardClick}
        onChildDoubleClick={onCardDoubleClick}
      />
    </div>
  );

  // Render cards for a list, inserting gap placeholder at the preview target index
  const renderCardsWithGap = (cardObjects: CrmObject[], rowId?: string) => {
    const preview = dragPreview;
    const showGap = preview &&
      preview.mode === "between" &&
      !preview.childReorder &&
      preview.targetColumn === id &&
      (rowId !== undefined ? preview.targetRow === rowId : !rows);
    if (!showGap) return cardObjects.map(obj => renderCard(obj));

    const sameColumn = preview.sourceColumn === preview.targetColumn;
    if (sameColumn) {
      // Same-column: remove card from list, insert gap with data-card-id at target.
      // The gap has data-card-id so calculateDropIndex will skip it, keeping
      // index calculations consistent between the first and subsequent dragover events.
      const filtered = cardObjects.filter(o => o.id !== preview.draggedId);
      const cards = filtered.map(obj => renderCard(obj));
      cards.splice(preview.targetIndex, 0, renderGap(preview.cardHeight, preview.draggedId));
      return cards;
    } else {
      // Cross-column: card already removed by applyPreviewToList, just insert gap
      const cards = cardObjects.map(obj => renderCard(obj));
      cards.splice(preview.targetIndex, 0, renderGap(preview.cardHeight));
      return cards;
    }
  };

  return (
    <div
      ref={columnRef}
      className={cn(
        "rounded-lg",
        rows ? "grid grid-rows-subgrid row-span-full" : "flex flex-col w-72 shrink-0 h-full",
        "bg-surface-1 overflow-hidden border border-border transition-colors",
        "data-drag-over:border-primary data-drag-over:bg-primary/5",
        isReordering && !isDragging && "border-dashed border-border-strong",
        isDragging && "border-primary border-2 bg-background shadow-lg",
      )}
      onDragStart={!onDrop || preview ? (e) => e.preventDefault() : undefined}
      onDragEnter={isReordering || preview ? undefined : handleDragEnter}
      onDragOver={isReordering || preview ? undefined : handleDragOver}
      onDragLeave={isReordering || preview ? undefined : handleDragLeave}
      onDrop={isReordering || preview ? undefined : handleDrop}
    >
      {/* Column header */}
      <div
        className="flex items-center justify-between p-3 border-b cursor-pointer bg-primary/10 text-primary"
        onDoubleClick={preview ? undefined : (e) => {
          if (!(e.target as HTMLElement).closest("[data-column-menu]")) {
            onCreateClick?.();
          }
        }}
      >
        <div className="flex items-center gap-2">
          {colour && (
            <div
              className="w-3 h-3 rounded-full"
              style={{ backgroundColor: colour }}
            />
          )}
          <TooltipProvider delayDuration={0}>
            <Tooltip>
              <TooltipTrigger asChild>
                <span className="font-medium text-sm">{name}</span>
              </TooltipTrigger>
              <TooltipContent>{totalCount} {totalCount === 1 ? "item" : "items"}</TooltipContent>
            </Tooltip>
          </TooltipProvider>
        </div>
        {!isReordering && (preview || onCreateClick || onRenameColumn || (totalCount === 0 && onDeleteColumn)) && (
          <DropdownMenu>
            <DropdownMenuTrigger asChild>
              <button type="button" data-column-menu className="rounded p-1 transition-colors hover:bg-interactive-hover active:bg-interactive-active">
                <MoreHorizontal className="size-4 text-muted-foreground" />
              </button>
            </DropdownMenuTrigger>
            <DropdownMenuContent align="end">
              {(onCreateClick || preview) && (
                <DropdownMenuItem onClick={preview ? undefined : onCreateClick}>
                  <Plus className="size-4 mr-2" />
                  Create
                </DropdownMenuItem>
              )}
              {(onRenameColumn || preview) && (
                <DropdownMenuItem
                  onClick={preview ? undefined : () => {
                    setNewName(name);
                    setShowRenameDialog(true);
                  }}
                >
                  <Pencil className="size-4 mr-2" />
                  Rename
                </DropdownMenuItem>
              )}
              {totalCount === 0 && (onDeleteColumn || preview) && (
                <DropdownMenuItem
                  onClick={preview ? undefined : () => setShowDeleteDialog(true)}
                >
                  <Trash2 className="size-4 mr-2" />
                  Delete
                </DropdownMenuItem>
              )}
            </DropdownMenuContent>
          </DropdownMenu>
        )}
      </div>

      <ResponsiveDialog open={showRenameDialog} onOpenChange={setShowRenameDialog}>
        <ResponsiveDialogContent>
          <form
            onSubmit={async (e) => {
              e.preventDefault();
              if (!newName.trim() || newName.trim() === name) {
                setShowRenameDialog(false);
                return;
              }
              setIsRenaming(true);
              try {
                await onRenameColumn?.(newName.trim());
                setShowRenameDialog(false);
              } finally {
                setIsRenaming(false);
              }
            }}
          >
            <ResponsiveDialogHeader>
              <ResponsiveDialogTitle>Rename column</ResponsiveDialogTitle>
              <ResponsiveDialogDescription className="sr-only">Rename this board column</ResponsiveDialogDescription>
            </ResponsiveDialogHeader>
            <div className="py-4 space-y-2">
              <Label htmlFor="column-name">Name</Label>
              <Input
                id="column-name"
                value={newName}
                onChange={(e) => setNewName(e.target.value)}
                autoFocus
              />
            </div>
            <ResponsiveDialogFooter>
              <Button
                type="button"
                variant="outline"
                onClick={() => setShowRenameDialog(false)}
              >
                Cancel
              </Button>
              <Button type="submit" disabled={!newName.trim() || isRenaming}>
                Rename
              </Button>
            </ResponsiveDialogFooter>
          </form>
        </ResponsiveDialogContent>
      </ResponsiveDialog>

      <ConfirmDialog
        open={showDeleteDialog}
        onOpenChange={setShowDeleteDialog}
        title="Delete column"
        desc={`Are you sure you want to delete the "${name}" column? This cannot be undone.`}
        confirmText="Delete"
        destructive
        isLoading={isDeleting}
        handleConfirm={async () => {
          if (totalCount > 0) {
            setShowDeleteDialog(false);
            return;
          }
          setIsDeleting(true);
          try {
            await onDeleteColumn?.();
            setShowDeleteDialog(false);
          } finally {
            setIsDeleting(false);
          }
        }}
      />

      {/* Drop indicator (portaled to body to avoid grid layout impact) */}
      {createPortal(
        <div
          ref={indicatorRef}
          className="fixed h-0.5 rounded-full bg-primary z-50 pointer-events-none opacity-0 -translate-y-1/2"
        />,
        document.body,
      )}

      {/* Cards */}
      {rows ? (
        rows.map((row, index) => (
          <div
            key={row.id}
            data-row-id={row.id}
            className={cn(
              "p-2 space-y-2",
              index < rows.length - 1 && "border-b"
            )}
            onDoubleClick={onCreateInRow && !preview ? (e) => {
              if (e.target === e.currentTarget || (e.target as HTMLElement).closest("[data-card-id]") === null) {
                onCreateInRow(row.id);
              }
            } : undefined}
          >
            {renderCardsWithGap(row.objects, row.id)}
          </div>
        ))
      ) : (
        <div
          ref={cardsContainerRef}
          className="p-2 space-y-2 flex-1 relative"
          onDoubleClick={preview ? undefined : (e) => {
            if (e.target === e.currentTarget || (e.target as HTMLElement).closest("[data-card-id]") === null) {
              onCreateClick?.();
            }
          }}
        >
          {renderCardsWithGap(objects)}

          {totalCount === 0 && !hideHeader && (
            <div className="flex flex-col items-center justify-center py-8 gap-2">
              <Inbox className="size-8 text-muted-foreground/30" />
              {(onCreateClick || preview) && (
                <button
                  type="button"
                  onClick={preview ? undefined : onCreateClick}
                  className="text-xs text-muted-foreground hover:text-foreground flex items-center gap-1"
                >
                  <Plus className="size-3" />
                  Create
                </button>
              )}
            </div>
          )}
        </div>
      )}
    </div>
  );
}
