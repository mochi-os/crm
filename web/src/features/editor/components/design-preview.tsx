// Mochi CRMs: Design preview component
// Copyright Alistair Cunningham 2026

import { useState } from "react";
import { Card, cn } from "@mochi/common";
import { ChevronDown, ChevronRight } from "lucide-react";
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

// Sample data for preview
const SAMPLE_CARDS = [
  {
    id: "1",
    values: {
      title: "Implement login feature",
      status: "progress",
      priority: "high",
      description: "Add user authentication",
    },
  },
  {
    id: "2",
    values: {
      title: "Fix navigation bug",
      status: "todo",
      priority: "medium",
      description: "Navigation not working on mobile",
    },
  },
  {
    id: "3",
    values: {
      title: "Update documentation",
      status: "done",
      priority: "low",
      description: "Add API documentation",
    },
  },
];

// Sample tree data for preview
const SAMPLE_TREE = [
  {
    id: "1",
    title: "Crm setup",
    status: "done",
    expanded: true,
    children: [
      {
        id: "2",
        title: "Configure build system",
        status: "done",
        children: [],
      },
      {
        id: "3",
        title: "Set up testing framework",
        status: "progress",
        children: [],
      },
    ],
  },
  {
    id: "4",
    title: "Core features",
    status: "progress",
    expanded: true,
    children: [
      {
        id: "5",
        title: "User authentication",
        status: "progress",
        children: [],
      },
      {
        id: "6",
        title: "Data persistence",
        status: "todo",
        children: [],
      },
    ],
  },
  {
    id: "7",
    title: "Documentation",
    status: "todo",
    children: [],
  },
];

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

  const cardFields = boardView?.fields?.split(",").filter(Boolean) || [];
  const columnField = boardView?.columns || "";
  const columnOptions = classOptions[columnField] || [];

  const renderFieldValue = (field: CrmField, value: string) => {
    if (!value) return null;

    if (field.fieldtype === "enumerated") {
      const fieldOpts = classOptions[field.id] || [];
      const opt = fieldOpts.find((o) => o.id === value);
      if (opt) {
        return (
          <span className="inline-flex items-center gap-1">
            <span
              className="size-2 rounded-full"
              style={{ backgroundColor: opt.colour }}
            />
            <span className="text-xs">{opt.name}</span>
          </span>
        );
      }
    }

    return <span className="text-xs text-muted-foreground">{value}</span>;
  };

  const renderCard = (card: (typeof SAMPLE_CARDS)[0]) => {
    return (
      <Card className="p-3 py-3">
        {cardFields.map((fieldId) => {
          const field = classFields.find((f) => f.id === fieldId);
          if (!field) return null;
          const value = card.values[fieldId as keyof typeof card.values];
          if (!value) return null;

          if (field.id === "title") {
            return (
              <div key={fieldId} className="font-medium text-sm">
                {value}
              </div>
            );
          }

          return <div key={fieldId}>{renderFieldValue(field, value)}</div>;
        })}
      </Card>
    );
  };

  const renderBoardPreview = () => {
    if (columnOptions.length === 0) {
      return (
        <div className="text-sm text-muted-foreground text-center py-8">
          Add options to the "{columnField}" field to see board columns
        </div>
      );
    }

    return (
      <div className="flex gap-4 overflow-x-auto pb-4">
        {columnOptions.slice(0, 4).map((opt) => (
          <div
            key={opt.id}
            className="w-64 shrink-0 bg-muted/50 rounded-lg p-3"
          >
            <div className="flex items-center gap-2 mb-3">
              <span
                className="size-3 rounded-full"
                style={{ backgroundColor: opt.colour }}
              />
              <span className="font-medium text-sm">{opt.name}</span>
              <span className="text-xs text-muted-foreground ml-auto">
                {
                  SAMPLE_CARDS.filter(
                    (c) =>
                      c.values[columnField as keyof typeof c.values] === opt.id,
                  ).length
                }
              </span>
            </div>
            <div className="space-y-2">
              {SAMPLE_CARDS.filter(
                (c) =>
                  c.values[columnField as keyof typeof c.values] === opt.id,
              ).map((card) => (
                <div key={card.id}>{renderCard(card)}</div>
              ))}
            </div>
          </div>
        ))}
      </div>
    );
  };

  const renderCardPreview = () => {
    const card = SAMPLE_CARDS[0];
    return (
      <div className="max-w-md mx-auto">
        <Card className="p-4 py-4 gap-0 space-y-4">
          {classFields.map((field) => {
            const value = card.values[field.id as keyof typeof card.values];
            return (
              <div key={field.id} className="space-y-1">
                <label className="text-xs font-medium text-muted-foreground">
                  {field.name}
                  {field.flags?.split(",").includes("required") && (
                    <span className="text-destructive ml-0.5">*</span>
                  )}
                </label>
                <div className="text-sm">
                  {renderFieldValue(field, value || "") || (
                    <span className="text-muted-foreground italic">Empty</span>
                  )}
                </div>
              </div>
            );
          })}
        </Card>
      </div>
    );
  };

  const renderListPreview = () => {
    const statusField = classFields.find((f) => f.fieldtype === "enumerated");
    const statusOptions = statusField ? classOptions[statusField.id] || [] : [];

    const getStatusColor = (statusId: string) => {
      const opt = statusOptions.find((o) => o.id === statusId);
      return opt?.colour || "#888";
    };

    type TreeItem = (typeof SAMPLE_TREE)[0];

    const renderTreeRow = (item: TreeItem, depth: number) => {
      const hasChildren = item.children && item.children.length > 0;
      const isExpanded = "expanded" in item && item.expanded;

      return (
        <div key={item.id}>
          <div className="flex items-center gap-1 py-1.5 px-2 hover:bg-muted/50 rounded text-sm">
            <div style={{ width: depth * 24 }} />
            <div className="w-5 flex items-center justify-center text-muted-foreground">
              {hasChildren ? (
                isExpanded ? (
                  <ChevronDown className="size-4" />
                ) : (
                  <ChevronRight className="size-4" />
                )
              ) : null}
            </div>
            <span className="flex-1">{item.title}</span>
            {statusField && (
              <span className="inline-flex items-center gap-1">
                <span
                  className="size-2 rounded-full"
                  style={{ backgroundColor: getStatusColor(item.status) }}
                />
              </span>
            )}
          </div>
          {hasChildren &&
            isExpanded &&
            item.children.map((child) => renderTreeRow(child as TreeItem, depth + 1))}
        </div>
      );
    };

    return (
      <div className="bg-background border rounded-[10px] overflow-hidden max-w-2xl">
        {SAMPLE_TREE.map((item) => renderTreeRow(item, 0))}
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
