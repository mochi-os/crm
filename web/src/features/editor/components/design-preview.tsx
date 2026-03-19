// Mochi CRMs: Design preview component
// Copyright Alistair Cunningham 2026

import { useMemo, useState } from "react";
import { Card, cn } from "@mochi/web";
import type {
  CrmClass,
  CrmField,
  FieldOption,
  CrmView,
  CrmObject,
} from "@/types";

type PreviewMode = "board" | "list" | "card";

interface DesignPreviewProps {
  classes: CrmClass[];
  fields: Record<string, CrmField[]>;
  options: Record<string, Record<string, FieldOption[]>>;
  views: CrmView[];
  objects: CrmObject[];
  selectedClassId: string | null;
}

export function DesignPreview({
  classes,
  fields,
  options,
  views,
  objects,
  selectedClassId,
}: DesignPreviewProps) {
  const [previewMode, setPreviewMode] = useState<PreviewMode>("board");

  const classId = selectedClassId || classes[0]?.id || "task";
  const classFields = fields[classId] || [];
  const classOptions = options[classId] || {};

  // Filter objects to the selected class
  const classObjects = useMemo(
    () => objects.filter((o) => o.class === classId),
    [objects, classId],
  );

  // Get the first board view
  const boardView = views.find((v) => v.viewtype === "board");

  const columnField = boardView?.columns || "";
  const columnOptions = classOptions[columnField] || [];
  const borderField = boardView?.border || "";

  // Get the title field for the selected class
  const titleFieldId = classes.find((c) => c.id === classId)?.title || "title";

  const renderBoardPreview = () => {
    if (columnOptions.length === 0) {
      return (
        <div className="text-sm text-muted-foreground text-center py-8">
          Add options to the &ldquo;{columnField}&rdquo; field to see board columns
        </div>
      );
    }

    return (
      <div className="flex gap-4 overflow-x-auto pb-4">
        {columnOptions.map((opt) => {
          const columnObjects = classObjects.filter(
            (o) => o.values[columnField] === opt.id,
          );
          return (
            <div
              key={opt.id}
              className="w-64 shrink-0 bg-muted/50 rounded-lg p-3 space-y-2"
            >
              <div className="flex items-center gap-2">
                <span
                  className="size-3 rounded-full"
                  style={{ backgroundColor: opt.colour }}
                />
                <span className="font-medium text-sm">{opt.name}</span>
                <span className="text-xs text-muted-foreground ml-auto">
                  {columnObjects.length}
                </span>
              </div>
              {columnObjects.slice(0, 5).map((obj) => {
                const borderValue = borderField ? obj.values[borderField] : "";
                const borderColor = borderValue
                  ? classOptions[borderField]?.find((o) => o.id === borderValue)?.colour
                  : undefined;
                return (
                  <div
                    key={obj.id}
                    className="bg-background rounded-[10px] p-2 text-sm border"
                    style={borderColor ? { borderColor } : undefined}
                  >
                    {obj.values[titleFieldId] || "Untitled"}
                  </div>
                );
              })}
              {columnObjects.length > 5 && (
                <div className="text-xs text-muted-foreground text-center">
                  +{columnObjects.length - 5} more
                </div>
              )}
            </div>
          );
        })}
      </div>
    );
  };

  const renderCardPreview = () => {
    if (classObjects.length === 0) {
      return (
        <div className="text-sm text-muted-foreground text-center py-8">
          No items
        </div>
      );
    }

    return (
      <div className="max-w-md mx-auto space-y-4">
        {classObjects.slice(0, 10).map((obj) => (
          <Card key={obj.id} className="p-4 py-4 gap-0 space-y-4">
            {classFields.map((field) => {
              const value = obj.values[field.id] || "";
              const displayValue =
                field.fieldtype === "enumerated"
                  ? classOptions[field.id]?.find((o) => o.id === value)?.name || value
                  : value;
              return (
                <div key={field.id} className="space-y-1">
                  <label className="text-xs font-medium text-muted-foreground">
                    {field.name}
                    {field.flags?.split(",").includes("required") && (
                      <span className="text-destructive ml-0.5">*</span>
                    )}
                  </label>
                  <div className={cn("text-sm", !displayValue && "text-muted-foreground italic")}>
                    {displayValue || "Empty"}
                  </div>
                </div>
              );
            })}
          </Card>
        ))}
        {classObjects.length > 10 && (
          <div className="text-xs text-muted-foreground text-center">
            +{classObjects.length - 10} more
          </div>
        )}
      </div>
    );
  };

  const renderListPreview = () => {
    const listFields = classFields.slice(0, 4);

    return (
      <div className="bg-background border rounded-[10px] overflow-hidden max-w-2xl">
        <div className="flex items-center gap-4 py-2 px-3 border-b bg-muted/30">
          <div className="w-5" />
          {listFields.map((field) => (
            <span key={field.id} className="text-xs font-medium text-muted-foreground flex-1">
              {field.name}
            </span>
          ))}
        </div>
        {classObjects.length === 0 ? (
          <div className="py-8 text-center text-sm text-muted-foreground">
            No items
          </div>
        ) : (
          classObjects.slice(0, 10).map((obj) => (
            <div key={obj.id} className="flex items-center gap-4 py-2 px-3 border-b last:border-b-0">
              <div className="w-5" />
              {listFields.map((field) => {
                const value = obj.values[field.id] || "";
                const displayValue =
                  field.fieldtype === "enumerated"
                    ? classOptions[field.id]?.find((o) => o.id === value)?.name || value
                    : value;
                return (
                  <span key={field.id} className="text-sm flex-1 truncate">
                    {displayValue}
                  </span>
                );
              })}
            </div>
          ))
        )}
        {classObjects.length > 10 && (
          <div className="py-2 text-center text-xs text-muted-foreground">
            +{classObjects.length - 10} more
          </div>
        )}
      </div>
    );
  };

  return (
    <div className="h-full flex flex-col">
      <div className="flex items-center gap-2 p-2 border-b">
        <span className="text-sm font-medium">Preview:</span>
        {(["board", "list", "card"] as const).map((mode) => (
          <button
            key={mode}
            onClick={() => setPreviewMode(mode)}
            className={cn(
              "px-2 py-1 text-sm rounded",
              previewMode === mode
                ? "bg-primary text-primary-foreground"
                : "hover:bg-muted",
            )}
          >
            {mode.charAt(0).toUpperCase() + mode.slice(1)}
          </button>
        ))}
      </div>
      <div className="flex-1 p-4 overflow-auto bg-muted/30">
        {previewMode === "board" && renderBoardPreview()}
        {previewMode === "list" && renderListPreview()}
        {previewMode === "card" && renderCardPreview()}
      </div>
    </div>
  );
}
