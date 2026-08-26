// Mochi CRMs: Edit dialogs for design editor
// Copyright © 2026 Mochisoft OÜ
// SPDX-License-Identifier: AGPL-3.0-only
// This file is part of Mochi, licensed under the GNU AGPL v3 with the
// Mochi Application Interface Exception - see license.txt and license-exception.md.

// ViewSheet and EditFieldDialog now live in @mochi/web. ClassSheet stays here:
// projects' copy carries a merge-requests switch and a wider onUpdate/onCreate
// signature that crm has no use for, so the two have not been merged.

import { useState, useEffect } from "react";
import { Trans } from '@lingui/react/macro'
import { t } from '@lingui/core/macro'
import {
  Sheet,
  SheetContent,
  SheetDescription,
  SheetTitle,
  SheetFooter,
  Button,
  Input,
  Label,
  naturalCompare,
  DropdownMenu,
  DropdownMenuTrigger,
  DropdownMenuContent,
  DropdownMenuItem,
  Select,
  SelectContent,
  SelectItem,
  SelectTrigger,
  SelectValue,
  Switch,
  Tooltip,
  TooltipTrigger,
  TooltipContent,
} from "@mochi/web";
import { Check, GripVertical, Minus, MoreHorizontal, Plus, X } from "lucide-react";
import type { CrmField, CrmClass } from "@/types";
import { AddFieldDialog } from "./add-dialogs";

export { ViewSheet, EditFieldDialog } from "@mochi/web";

const NONE_SELECT_VALUE = "_none_";

// Pending field for create mode
export interface PendingField {
  id: string;
  name: string;
  fieldtype: string;
  flags?: string;
  rows?: number;
  options?: { name: string; colour: string }[];
}

interface ClassSheetProps {
  open: boolean;
  onOpenChange: (open: boolean) => void;
  mode?: "create" | "edit";
  classes: CrmClass[];
  // Edit mode props
  cls?: CrmClass | null;
  hierarchy?: string[];
  fields?: CrmField[];
  onUpdate?: (name: string, title?: string) => void;
  onUpdateHierarchy?: (parents: string[]) => void;
  onDelete?: () => void;
  onAddField?: () => void;
  onEditField?: (field: CrmField) => void;
  onReorderFields?: (order: string[]) => void;
  // Create mode props
  onCreate?: (name: string, parents: string[], fields: PendingField[]) => void | Promise<void>;
}

export function ClassSheet({
  open,
  onOpenChange,
  mode = "edit",
  classes,
  cls,
  hierarchy,
  fields,
  onUpdate,
  onUpdateHierarchy,
  onDelete,
  onAddField,
  onEditField,
  onReorderFields,
  onCreate,
}: ClassSheetProps) {
  const [name, setName] = useState("");
  const [draggedFieldId, setDraggedFieldId] = useState<string | null>(null);
  const [dropIndicator, setDropIndicator] = useState<{ fieldId: string; position: "before" | "after" } | null>(null);

  // Create mode state
  const [pendingParents, setPendingParents] = useState<string[]>([]);
  const [pendingFields, setPendingFields] = useState<PendingField[]>([]);
  const [addFieldOpen, setAddFieldOpen] = useState(false);

  // Reset state on open
  useEffect(() => {
    if (!open) return;
    if (mode === "create") {
      setName("");
      // Root, matching what the server writes for a new class.
      setPendingParents([""]);
      setPendingFields([{ id: "title", name: t`Title`, fieldtype: "text", flags: "required,sort" }]);
    } else if (cls) {
      setName(cls.name);
    }
  }, [open, cls, mode]);

  if (mode === "edit" && !cls) return null;

  const handleNameBlur = () => {
    if (mode === "edit" && onUpdate && cls && name.trim() && name.trim() !== cls.name) {
      onUpdate(name.trim(), undefined);
    }
  };

  // Parent toggling
  const toggleParent = (parentId: string) => {
    if (mode === "create") {
      setPendingParents((prev) =>
        prev.includes(parentId) ? prev.filter((p) => p !== parentId) : [...prev, parentId]
      );
    } else if (onUpdateHierarchy && hierarchy) {
      const newParents = hierarchy.includes(parentId)
        ? hierarchy.filter((p) => p !== parentId)
        : [...hierarchy, parentId];
      onUpdateHierarchy(newParents);
    }
  };

  const currentHierarchy = mode === "create" ? pendingParents : (hierarchy || []);
  const displayFields = mode === "create" ? pendingFields : (fields || []);

  // Drag and drop for fields
  const handleDragStart = (e: React.DragEvent, fieldId: string) => {
    setDraggedFieldId(fieldId);
    e.dataTransfer.effectAllowed = "move";
    e.dataTransfer.setData("text/plain", fieldId);
  };

  const handleDragEnd = () => {
    setDraggedFieldId(null);
    setDropIndicator(null);
  };

  const handleDragOver = (e: React.DragEvent, fieldId: string) => {
    e.preventDefault();
    if (fieldId === draggedFieldId) return;
    const rect = e.currentTarget.getBoundingClientRect();
    const midY = rect.top + rect.height / 2;
    const position = e.clientY < midY ? "before" : "after";
    setDropIndicator({ fieldId, position });
  };

  const handleDragLeave = () => {
    setDropIndicator(null);
  };

  const handleDrop = (e: React.DragEvent, targetFieldId: string) => {
    e.preventDefault();
    if (!draggedFieldId || draggedFieldId === targetFieldId) return;

    if (mode === "create") {
      const currentOrder = pendingFields.map((f) => f.id);
      const draggedIndex = currentOrder.indexOf(draggedFieldId);
      const targetIndex = currentOrder.indexOf(targetFieldId);
      if (draggedIndex === -1 || targetIndex === -1) return;

      const newFields = [...pendingFields];
      const [dragged] = newFields.splice(draggedIndex, 1);
      const insertIndex = dropIndicator?.position === "after"
        ? currentOrder.indexOf(targetFieldId) - (draggedIndex < targetIndex ? 1 : 0) + 1
        : currentOrder.indexOf(targetFieldId) - (draggedIndex < targetIndex ? 1 : 0);
      newFields.splice(insertIndex, 0, dragged);
      setPendingFields(newFields);
    } else if (onReorderFields && fields) {
      const currentOrder = fields.map((f) => f.id);
      const draggedIndex = currentOrder.indexOf(draggedFieldId);
      const targetIndex = currentOrder.indexOf(targetFieldId);
      if (draggedIndex === -1 || targetIndex === -1) return;

      const newOrder = [...currentOrder];
      newOrder.splice(draggedIndex, 1);
      const insertIndex = dropIndicator?.position === "after"
        ? currentOrder.indexOf(targetFieldId) - (draggedIndex < targetIndex ? 1 : 0) + 1
        : currentOrder.indexOf(targetFieldId) - (draggedIndex < targetIndex ? 1 : 0);
      newOrder.splice(insertIndex, 0, draggedFieldId);
      onReorderFields(newOrder);
    }

    setDraggedFieldId(null);
    setDropIndicator(null);
  };

  const removePendingField = (fieldId: string) => {
    setPendingFields((prev) => prev.filter((f) => f.id !== fieldId));
  };

  const handleCreate = async () => {
    if (onCreate && name.trim()) {
      try {
        await onCreate(name.trim(), pendingParents, pendingFields);
        onOpenChange(false);
      } catch {
        // Error displayed by caller via toast
      }
    }
  };

  return (
    <Sheet open={open} onOpenChange={onOpenChange}>
      <SheetContent className="w-full sm:max-w-md p-0 flex flex-col [&>button:last-child]:hidden" onOpenAutoFocus={(event) => event.preventDefault()}>
        <div className="flex items-center justify-between px-6 py-4 border-b">
          <SheetTitle>{mode === "create" ? <Trans>Add class</Trans> : <Trans>Edit class</Trans>}</SheetTitle>
          <SheetDescription className="sr-only"><Trans>Configure class settings</Trans></SheetDescription>
          <div className="flex items-center gap-1">
            <Tooltip>
              <TooltipTrigger asChild>
                <Button variant="ghost" size="icon" className="size-8" onClick={() => onOpenChange(false)} aria-label={t`Close dialog`}>
                  <X className="size-4" />
                </Button>
              </TooltipTrigger>
              <TooltipContent>{t`Close dialog`}</TooltipContent>
            </Tooltip>
            {mode === "edit" && onDelete && (
              <DropdownMenu>
                <Tooltip>
                  <TooltipTrigger asChild>
                    <DropdownMenuTrigger asChild>
                      <Button variant="ghost" size="icon" className="size-8" aria-label={t`Open class actions`}>
                        <MoreHorizontal className="size-4" />
                      </Button>
                    </DropdownMenuTrigger>
                  </TooltipTrigger>
                  <TooltipContent>{t`Open class actions`}</TooltipContent>
                </Tooltip>
                <DropdownMenuContent align="end" onCloseAutoFocus={(e) => e.preventDefault()}>
                  <DropdownMenuItem onSelect={onDelete}>
                    <Minus className="size-4" />
                    <Trans>Delete class</Trans>
                  </DropdownMenuItem>
                </DropdownMenuContent>
              </DropdownMenu>
            )}
          </div>
        </div>
        <div className="flex-1 overflow-y-auto p-6 space-y-6">
          <div className="space-y-2">
            <Label htmlFor="class-name"><Trans>Name</Trans></Label>
            <div className="ps-4">
              <Input
                id="class-name"
                value={name}
                onChange={(e) => setName(e.target.value)}
                onBlur={mode === "edit" ? handleNameBlur : undefined}
                autoFocus={mode === "create"}
              />
            </div>
          </div>

          {mode === "edit" && cls && (
            <div className="space-y-2">
              <Label htmlFor="class-id"><Trans>ID</Trans></Label>
              <div className="ps-4">
                <Input id="class-id" value={cls.id} readOnly className="text-muted-foreground" />
              </div>
            </div>
          )}

          {mode === "edit" && cls && fields && fields.length > 0 && (
            <div className="space-y-2">
              <Label><Trans>Title field</Trans></Label>
              <div className="ps-4">
                <Select
                  value={cls.title || NONE_SELECT_VALUE}
                  onValueChange={(value) => {
                    if (onUpdate) {
                      onUpdate(cls.name, value === NONE_SELECT_VALUE ? "" : value);
                    }
                  }}
                >
                  <SelectTrigger className="w-full">
                    <SelectValue placeholder={t`None`} />
                  </SelectTrigger>
                  <SelectContent>
                    <SelectItem value={NONE_SELECT_VALUE}><Trans>None</Trans></SelectItem>
                    {fields.map((field) => (
                      <SelectItem key={field.id} value={field.id}>
                        {field.name}
                      </SelectItem>
                    ))}
                  </SelectContent>
                </Select>
              </div>
            </div>
          )}

          <div className="space-y-2">
            <Label><Trans>Can be child of</Trans></Label>
            <div className="ps-4 space-y-2">
              <label className="flex items-center gap-2 text-sm cursor-pointer">
                <Switch
                  checked={currentHierarchy.includes("")}
                  onCheckedChange={() => toggleParent("")}
                />
                <Trans>Top level</Trans>
              </label>
              {[...classes].sort((a, b) => naturalCompare(a.name, b.name)).map((c) => (
                <label
                  key={c.id}
                  className="flex items-center gap-2 text-sm cursor-pointer"
                >
                  <Switch
                    checked={currentHierarchy.includes(c.id)}
                    onCheckedChange={() => toggleParent(c.id)}
                  />
                  {c.name}{c.id === cls?.id ? <> <Trans>(itself)</Trans></> : ""}
                </label>
              ))}
            </div>
          </div>

          <div className="space-y-2">
            <Label><Trans>Fields</Trans></Label>
            <div className="ps-4 space-y-2">
              <div className="space-y-1">
                {displayFields.map((field) => (
                  <div key={field.id}>
                    {dropIndicator?.fieldId === field.id && dropIndicator.position === "before" && (
                      <div className="h-0.5 bg-primary mx-3 rounded-full" />
                    )}
                    <div
                      draggable
                      onDragStart={(e) => handleDragStart(e, field.id)}
                      onDragEnd={handleDragEnd}
                      onDragOver={(e) => handleDragOver(e, field.id)}
                      onDragLeave={handleDragLeave}
                      onDrop={(e) => handleDrop(e, field.id)}
                      className={`flex items-center gap-2 px-3 py-2 text-sm rounded-md hover:bg-hover transition-colors cursor-grab ${
                        draggedFieldId === field.id ? "opacity-50" : ""
                      }`}
                    >
                      <GripVertical className="size-4 text-muted-foreground shrink-0" />
                      {mode === "edit" && onEditField ? (
                        <button
                          type="button"
                          onClick={() => onEditField(field as CrmField)}
                          className="flex-1 text-start"
                        >
                          <span className="font-medium">{field.name || field.id}</span>
                        </button>
                      ) : (
                        <span className="flex-1 text-start font-medium">
                          {field.name || field.id}
                        </span>
                      )}
                      {mode === "create" && field.id !== "title" && (
                        <Tooltip>
                          <TooltipTrigger asChild>
                            <Button
                              type="button"
                              variant="ghost"
                              size="icon"
                              className="size-6 shrink-0"
                              onClick={() => removePendingField(field.id)}
                              aria-label={t`Remove field ${field.name || field.id}`}
                            >
                              <X className="size-3" />
                            </Button>
                          </TooltipTrigger>
                          <TooltipContent>{t`Remove field ${field.name || field.id}`}</TooltipContent>
                        </Tooltip>
                      )}
                    </div>
                    {dropIndicator?.fieldId === field.id && dropIndicator.position === "after" && (
                      <div className="h-0.5 bg-primary mx-3 rounded-full" />
                    )}
                  </div>
                ))}
              </div>
            </div>
          </div>
        </div>
        <SheetFooter className="px-6 py-4 border-t justify-between">
          <Button
            type="button"
            variant="outline"
            size="sm"
            onClick={() => {
              if (mode === "create") {
                setAddFieldOpen(true);
              } else if (onAddField) {
                onAddField();
              }
            }}
          >
            <Plus className="size-4" />
            <Trans>Add field</Trans>
          </Button>
          {mode === "create" ? (
            <Button type="button" onClick={handleCreate} disabled={!name.trim()}>
              <Check className="size-4" />
              <Trans>Add class</Trans>
            </Button>
          ) : (
            <Button type="button" onClick={() => onOpenChange(false)}>
              <Check className="size-4" />
              <Trans>Done</Trans>
            </Button>
          )}
        </SheetFooter>
      </SheetContent>

      {mode === "create" && (
        <AddFieldDialog
          open={addFieldOpen}
          onOpenChange={setAddFieldOpen}
          onAdd={(fieldName, fieldtype, rows, options) => {
            setPendingFields((prev) => [
              ...prev,
              {
                id: crypto.randomUUID(),
                name: fieldName,
                fieldtype,
                rows,
                options: options?.map((o) => ({ name: o.name, colour: o.colour })),
              },
            ]);
          }}
        />
      )}
    </Sheet>
  );
}

// Edit Field Dialog (keep as dialog since it's nested)
