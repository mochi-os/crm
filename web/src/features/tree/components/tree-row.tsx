// Mochi CRMs: Tree row component
// Copyright Alistair Cunningham 2026

import { useRef } from "react";
import { CheckSquare, ChevronRight, ChevronDown, GripVertical } from "lucide-react";
import { cn } from "@mochi/common";
import type { CrmObject, CrmField, FieldOption, ChecklistItem } from "@/types";

interface TreeRowProps {
  object: CrmObject;
  depth: number;
  hasChildren: boolean;
  isExpanded: boolean;
  anySiblingHasChildren: boolean;
  fields: CrmField[];
  options: Record<string, FieldOption[]>;
  peopleMap: Record<string, string>;
  classMap: Record<string, string>;
  titleFieldId?: string;
  prefix: string;
  showClass?: boolean;
  showId?: boolean;
  isDragOver: boolean;
  isDragBefore: boolean;
  isDragAfter: boolean;
  canReorder: boolean;
  canReparent: boolean;
  onToggleExpand: () => void;
  onClick: () => void;
  onDragStart: () => void;
  onDragOver: (objectId: string, position: "before" | "after" | "on") => void;
  onDragEnd: () => void;
}

function truncate(text: string, maxLength: number): string {
  if (text.length <= maxLength) return text;
  return text.slice(0, maxLength - 1) + "…";
}

export function TreeRow({
  object,
  depth,
  hasChildren,
  isExpanded,
  anySiblingHasChildren,
  fields,
  options,
  peopleMap,
  classMap,
  titleFieldId,
  prefix,
  showClass = true,
  showId = true,
  isDragOver,
  isDragBefore,
  isDragAfter,
  canReorder,
  canReparent,
  onToggleExpand,
  onClick,
  onDragStart,
  onDragOver,
  onDragEnd,
}: TreeRowProps) {
  const rowRef = useRef<HTMLTableRowElement>(null);

  const renderFieldValue = (field: CrmField, value: string) => {
    if (!value) {
      return <span className="text-muted-foreground">-</span>;
    }

    switch (field.fieldtype) {
      case "enumerated": {
        const fieldOptions = options[field.id] || [];
        const option = fieldOptions.find((o) => o.id === value);
        if (option) {
          return (
            <span className="inline-flex items-center gap-1.5">
              <span
                className="size-2 rounded-full shrink-0"
                style={{ backgroundColor: option.colour }}
              />
              <span className="truncate">{option.name}</span>
            </span>
          );
        }
        return <span className="truncate">{value}</span>;
      }

      case "date": {
        const date = new Date(value + "T00:00:00");
        return (
          <span className="truncate">
            {date.toLocaleDateString()}
          </span>
        );
      }

      case "user": {
        const name = peopleMap[value] || value;
        return <span className="truncate">{truncate(name, 25)}</span>;
      }

      case "checklist": {
        try {
          const items: ChecklistItem[] = JSON.parse(value);
          if (items.length === 0) {
            return <span className="text-muted-foreground">-</span>;
          }
          const doneCount = items.filter((item) => item.done).length;
          const allDone = doneCount === items.length;
          return (
            <span
              className={cn(
                "inline-flex items-center gap-1 rounded-md px-1.5 py-0.5 text-xs font-medium ring-1 ring-inset",
                allDone
                  ? "bg-green-500/10 text-green-600 ring-green-500/30"
                  : "bg-muted text-muted-foreground ring-border"
              )}
            >
              <CheckSquare className="size-3" />
              {doneCount}/{items.length}
            </span>
          );
        } catch {
          return <span className="text-muted-foreground">-</span>;
        }
      }

      case "text":
      default:
        return <span className="truncate">{value}</span>;
    }
  };

  // Calculate indentation (24px per level, applied to first content column)
  const indentPx = depth * 24;
  const firstContentCol = showClass ? "class" : showId ? "id" : fields[0]?.id || "";
  const indentStyle = indentPx > 0 ? { paddingLeft: indentPx } : undefined;

  // Determine drop position based on mouse position within row
  const handleDragOver = (e: React.DragEvent) => {
    e.preventDefault();

    if (!rowRef.current) return;

    const rect = rowRef.current.getBoundingClientRect();
    const y = e.clientY - rect.top;
    const height = rect.height;

    // Use larger edge zones (8px) for reorder, center for reparent
    const edgeZone = 8;

    if (canReorder && y < edgeZone) {
      onDragOver(object.id, "before");
    } else if (canReorder && y > height - edgeZone) {
      onDragOver(object.id, "after");
    } else if (canReparent) {
      onDragOver(object.id, "on");
    } else if (canReorder) {
      // If can't reparent but can reorder, use before/after based on half
      if (y < height * 0.5) {
        onDragOver(object.id, "before");
      } else {
        onDragOver(object.id, "after");
      }
    }
  };

  return (
    <tr
      ref={rowRef}
      data-card-id={object.id}
      className={cn(
        "hover:bg-muted/50 cursor-pointer text-sm group relative",
        isDragOver && "bg-primary/20 ring-2 ring-inset ring-primary/50",
      )}
      onClick={onClick}
      draggable
      onDragStart={(e) => {
        e.dataTransfer.effectAllowed = "move";
        e.dataTransfer.setData("text/plain", object.id);
        onDragStart();
      }}
      onDragOver={handleDragOver}
      onDrop={onDragEnd}
      onDragEnd={onDragEnd}
    >
      {/* Drop indicator - before */}
      {isDragBefore && (
        <td colSpan={100} className="absolute -top-px left-0 right-0 pointer-events-none">
          <div className="relative h-0.5 bg-primary shadow-[0_0_4px_1px] shadow-primary/50">
            <div className="absolute -left-1 -top-[3px] size-2 rounded-full bg-primary" />
          </div>
        </td>
      )}

      {/* Drag handle + expand/collapse */}
      <td className="whitespace-nowrap py-1.5 pl-1 pr-0 w-0">
        <div className="flex items-center">
          <div className="w-5 flex items-center justify-center opacity-0 group-hover:opacity-50 cursor-grab">
            <GripVertical className="size-3" />
          </div>
          {hasChildren ? (
            <button
              className="size-5 flex items-center justify-center hover:bg-muted rounded"
              onClick={(e) => {
                e.stopPropagation();
                onToggleExpand();
              }}
            >
              {isExpanded ? (
                <ChevronDown className="size-4" />
              ) : (
                <ChevronRight className="size-4" />
              )}
            </button>
          ) : anySiblingHasChildren ? (
            <div className="size-5" />
          ) : null}
        </div>
      </td>

      {/* Class badge */}
      {showClass && (
        <td className="whitespace-nowrap pl-1 pr-2 py-1.5" style={firstContentCol === "class" ? indentStyle : undefined}>
          <span className="text-xs text-muted-foreground bg-muted px-1.5 py-0.5 rounded">
            {classMap[object.class] || object.class}
          </span>
        </td>
      )}

      {/* Object number */}
      {showId && (
        <td className="whitespace-nowrap pl-1 pr-2 py-1.5 text-xs text-muted-foreground font-mono" style={firstContentCol === "id" ? indentStyle : undefined}>
          {prefix}-{object.number}
        </td>
      )}

      {/* Field columns */}
      {fields.map((field) => {
        const isTitleField = field.id === titleFieldId;
        const value = object.values[field.id] || "";
        const displayValue = isTitleField ? truncate(value, 100) : value;
        return (
          <td
            key={field.id}
            className={cn(
              "px-2 py-1.5",
              isTitleField ? "" : "whitespace-nowrap"
            )}
            style={firstContentCol === field.id ? indentStyle : undefined}
          >
            {renderFieldValue(field, displayValue)}
          </td>
        );
      })}

      {/* Drop indicator - after */}
      {isDragAfter && (
        <td colSpan={100} className="absolute -bottom-px left-0 right-0 pointer-events-none">
          <div className="relative h-0.5 bg-primary shadow-[0_0_4px_1px] shadow-primary/50">
            <div className="absolute -left-1 -top-[3px] size-2 rounded-full bg-primary" />
          </div>
        </td>
      )}
    </tr>
  );
}
