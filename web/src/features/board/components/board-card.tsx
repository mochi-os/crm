// Mochi CRMs: Board card component
// Copyright Alistair Cunningham 2026

import { useState } from "react";
import { Card, cn } from "@mochi/common";
import { Check, CheckSquare, ChevronDown, ChevronRight } from "lucide-react";
import type { CrmObject, CrmField, CrmClass, FieldOption, ChecklistItem } from "@/types";

interface BoardCardProps {
  object: CrmObject;
  fields: CrmField[];
  options: Record<string, FieldOption[]>;
  prefix: string;
  objectMap?: Record<string, CrmObject>;
  allFields?: Record<string, CrmField[]>;
  allObjects?: CrmObject[];
  statusField?: string;
  rowField?: string;
  borderField?: string;
  classMap?: Record<string, CrmClass>;
  peopleMap?: Record<string, string>;
  draggable?: boolean;
  onClick?: () => void;
  onDoubleClick?: () => void;
  children?: CrmObject[];
  childrenByParent?: Record<string, CrmObject[]>;
  depth?: number;
  hierarchy?: Record<string, string[]>;
  onChildClick?: (object: CrmObject) => void;
  onChildDoubleClick?: (object: CrmObject) => void;
}

const MAX_NESTING_DEPTH = 3;

function truncate(text: string, maxLength: number): string {
  if (text.length <= maxLength) return text;
  return text.slice(0, maxLength - 1) + "…";
}

// Format a date value for display
function formatDate(value: string): string {
  const date = new Date(value + "T00:00:00");
  return date.toLocaleDateString();
}

export function BoardCard({
  object,
  fields,
  options,
  prefix,
  objectMap,
  allFields,
  allObjects,
  statusField,
  rowField,
  borderField,
  classMap,
  peopleMap,
  draggable: canDrag = true,
  onClick,
  onDoubleClick,
  children: childObjects,
  childrenByParent,
  depth = 0,
  hierarchy,
  onChildClick,
  onChildDoubleClick,
}: BoardCardProps) {
  const [collapsed, setCollapsed] = useState(false);

  const isNested = depth > 0;

  // Use the class's title field as the card header
  const cls = classMap?.[object.class];
  const titleFieldId = cls?.title;
  const headerField = titleFieldId ? fields.find((f) => f.id === titleFieldId) : undefined;
  const rawTitle = headerField
    ? (object.values[headerField.id] || `${prefix}-${object.number}`)
    : `${prefix}-${object.number}`;
  const title = truncate(rawTitle, 160);

  // Body fields: exclude the header field, statusField, and rowField
  const cardFields = fields.filter(
    (f) => f !== headerField && f.id !== statusField && f.id !== rowField,
  );

  // Get border color from the view's border field
  let borderColor: string | undefined;
  if (borderField) {
    const value = object.values[borderField];
    if (value) {
      const match = options[borderField]?.find((o) => o.id === value && o.colour);
      if (match) {
        borderColor = match.colour;
      }
    }
  }

  // Count total nested children beyond depth cap
  const countDeepChildren = (objId: string): number => {
    const kids = childrenByParent?.[objId] || [];
    let count = kids.length;
    for (const kid of kids) {
      count += countDeepChildren(kid.id);
    }
    return count;
  };

  // Render a field value inline on the card
  const renderField = (field: CrmField) => {
    const value = object.values[field.id];
    if (!value) return null;

    const fieldOptions = options[field.id] || [];
    const option = fieldOptions.find((o) => o.id === value);

    switch (field.fieldtype) {
      case "enumerated":
        if (!option) return null;
        return (
          <span
            key={field.id}
            className="inline-flex items-center gap-1 text-[10px] text-muted-foreground"
          >
            {option.colour && (
              <span className="w-2 h-2 rounded-full shrink-0" style={{ backgroundColor: option.colour }} />
            )}
            {option.name}
          </span>
        );

      case "checklist":
        try {
          const items: ChecklistItem[] = JSON.parse(value);
          if (items.length === 0) return null;
          const doneCount = items.filter((item) => item.done).length;
          const allDone = doneCount === items.length;
          return (
            <span
              key={field.id}
              className={cn(
                "inline-flex items-center gap-1 rounded-md px-1.5 py-0.5 text-[10px] font-medium ring-1 ring-inset",
                allDone
                  ? "bg-green-500/10 text-green-600 ring-green-500/30"
                  : "bg-surface-2 text-muted-foreground ring-border"
              )}
            >
              <CheckSquare className="h-3 w-3" />
              {doneCount}/{items.length}
            </span>
          );
        } catch {
          return null;
        }

      case "date":
        return (
          <span key={field.id} className="text-[10px] text-muted-foreground">
            {formatDate(value)}
          </span>
        );

      case "user": {
        const name = peopleMap?.[value] || value;
        return (
          <span key={field.id} className="text-[10px] text-muted-foreground">
            {truncate(name, 25)}
          </span>
        );
      }

      case "checkbox":
        if (value !== "true") return null;
        return (
          <span
            key={field.id}
            className="inline-flex items-center gap-1 text-[10px] text-muted-foreground"
          >
            <Check className="h-3 w-3" />
            {field.name}
          </span>
        );

      case "number":
        return (
          <span key={field.id} className="text-[10px] text-muted-foreground">
            {value}
          </span>
        );

      case "text":
      default:
        return (
          <span key={field.id} className="text-[10px] text-muted-foreground truncate max-w-[200px]">
            {truncate(value, 80)}
          </span>
        );
    }
  };

  // Check if any body field has a value to render
  const hasBodyFields = !isNested && cardFields.some((f) => {
    const value = object.values[f.id];
    if (!value) return false;
    if (f.fieldtype === "checkbox" && value !== "true") return false;
    return true;
  });

  const hasChildren = childObjects && childObjects.length > 0;
  const atDepthCap = depth >= MAX_NESTING_DEPTH;

  return (
    <Card
      className={cn(
        "group/card relative transition-all",
        isNested ? "bg-surface-1 p-2" : "p-3 py-3 hover:bg-surface-2 hover:shadow-md",
        "cursor-pointer active:scale-[0.99]",
      )}
      style={borderColor ? { borderColor: borderColor } : undefined}
      onClick={(e) => {
        e.stopPropagation();
        onClick?.();
      }}
      onDoubleClick={onDoubleClick ? (e) => {
        e.stopPropagation();
        onDoubleClick();
      } : undefined}
      draggable={canDrag}
      onDragStart={canDrag ? (e) => {
        e.stopPropagation();
        e.dataTransfer.setData("text/plain", object.id);
        e.dataTransfer.setData(`application/x-mochi-class-${object.class}`, "");
        e.dataTransfer.setData(`application/x-mochi-id-${object.id}`, "");
        e.dataTransfer.effectAllowed = "move";
      } : undefined}
    >
      {/* Header row */}
      <div className="flex items-baseline gap-1.5">
        {hasChildren && (
          <button
            className="text-muted-foreground -ml-1 shrink-0 self-center rounded p-0.5 transition-colors hover:bg-interactive-hover active:bg-interactive-active"
            onClick={(e) => {
              e.stopPropagation();
              setCollapsed(!collapsed);
            }}
          >
            {collapsed ? (
              <ChevronRight className="size-3.5" />
            ) : (
              <ChevronDown className="size-3.5" />
            )}
          </button>
        )}
        <div className={cn(
          "font-medium leading-tight text-card-foreground flex-1 min-w-0",
          isNested ? "text-xs" : "text-sm",
        )}>
          {title}
        </div>
        {hasChildren && collapsed && (
          <span className="text-[10px] text-muted-foreground shrink-0 tabular-nums">
            {childObjects.length}
          </span>
        )}
      </div>

      {/* Body fields (top-level only) */}
      {hasBodyFields && (
        <div className="flex flex-col gap-1">
          {cardFields.map((field) => renderField(field))}
        </div>
      )}

      {/* Nested children */}
      {hasChildren && !collapsed && (
        <div className="mt-2 space-y-1.5 border-t pt-2">
          {atDepthCap ? (
            <span className="text-[10px] text-muted-foreground">
              +{countDeepChildren(object.id)} nested
            </span>
          ) : (
            childObjects.map((child) => {
              const childFields = allFields?.[child.class] || fields;
              const childOptions = allFields
                ? Object.fromEntries(
                    childFields.map((f) => [f.id, options[f.id] || []])
                  )
                : options;
              return (
                <div key={child.id} data-card-id={child.id} className="rounded-[10px] data-[drop-target]:ring-2 data-[drop-target]:ring-primary">
                  <BoardCard
                    object={child}
                    fields={childFields}
                    options={childOptions}
                    prefix={prefix}
                    objectMap={objectMap}
                    allFields={allFields}
                    allObjects={allObjects}
                    statusField={statusField}
                    rowField={rowField}
                    borderField={borderField}
                    classMap={classMap}
                    peopleMap={peopleMap}
                    draggable={canDrag}
                    onClick={() => onChildClick?.(child)}
                    onDoubleClick={onChildDoubleClick ? () => onChildDoubleClick(child) : undefined}
                    children={childrenByParent?.[child.id] || []}
                    childrenByParent={childrenByParent}
                    depth={depth + 1}
                    hierarchy={hierarchy}
                    onChildClick={onChildClick}
                    onChildDoubleClick={onChildDoubleClick}
                  />
                </div>
              );
            })
          )}
        </div>
      )}
    </Card>
  );
}
