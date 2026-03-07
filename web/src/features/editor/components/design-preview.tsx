// Mochi CRMs: Design preview component
// Copyright Alistair Cunningham 2026

import { useState } from "react";
import { Card, cn } from "@mochi/common";
import type {
  CrmClass,
  CrmField,
  FieldOption,
  CrmView,
} from "@/types";

type PreviewMode = "board" | "list" | "card";

interface DesignPreviewProps {
  classes: CrmClass[];
  fields: Record<string, CrmField[]>;
  options: Record<string, Record<string, FieldOption[]>>;
  views: CrmView[];
  selectedClassId: string | null;
}

export function DesignPreview({
  classes,
  fields,
  options,
  views,
  selectedClassId,
}: DesignPreviewProps) {
  const [previewMode, setPreviewMode] = useState<PreviewMode>("board");

  const classId = selectedClassId || classes[0]?.id || "task";
  const classFields = fields[classId] || [];
  const classOptions = options[classId] || {};

  // Get the first board view
  const boardView = views.find((v) => v.viewtype === "board");

  const columnField = boardView?.columns || "";
  const columnOptions = classOptions[columnField] || [];

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
        {columnOptions.map((opt) => (
          <div
            key={opt.id}
            className="w-64 shrink-0 bg-muted/50 rounded-lg p-3"
          >
            <div className="flex items-center gap-2">
              <span
                className="size-3 rounded-full"
                style={{ backgroundColor: opt.colour }}
              />
              <span className="font-medium text-sm">{opt.name}</span>
              <span className="text-xs text-muted-foreground ml-auto">0</span>
            </div>
          </div>
        ))}
      </div>
    );
  };

  const renderCardPreview = () => {
    return (
      <div className="max-w-md mx-auto">
        <Card className="p-4 py-4 gap-0 space-y-4">
          {classFields.map((field) => (
            <div key={field.id} className="space-y-1">
              <label className="text-xs font-medium text-muted-foreground">
                {field.name}
                {field.flags?.split(",").includes("required") && (
                  <span className="text-destructive ml-0.5">*</span>
                )}
              </label>
              <div className="text-sm text-muted-foreground italic">
                {field.fieldtype === "enumerated"
                  ? (classOptions[field.id]?.[0]?.name || "Empty")
                  : "Empty"}
              </div>
            </div>
          ))}
        </Card>
      </div>
    );
  };

  const renderListPreview = () => {
    const listFields = classFields.slice(0, 4);

    return (
      <div className="bg-background border rounded-[10px] overflow-hidden max-w-2xl">
        <div className="flex items-center gap-4 py-2 px-3 border-b bg-muted/30">
          <div className="w-5" />
          <span className="text-xs font-medium text-muted-foreground w-16">ID</span>
          {listFields.map((field) => (
            <span key={field.id} className="text-xs font-medium text-muted-foreground flex-1">
              {field.name}
            </span>
          ))}
        </div>
        <div className="py-8 text-center text-sm text-muted-foreground">
          No items
        </div>
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
