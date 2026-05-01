// Mochi CRMs: Edit dialogs for design editor
// Copyright Alistair Cunningham 2026

import { useState, useEffect, useMemo } from "react";
import { Trans } from '@lingui/react/macro'
import { t } from '@lingui/core/macro'
import {
  Sheet,
  SheetContent,
  SheetDescription,
  SheetTitle,
  SheetFooter,
  ResponsiveDialog,
  ResponsiveDialogContent,
  ResponsiveDialogDescription,
  ResponsiveDialogHeader,
  ResponsiveDialogTitle,
  ResponsiveDialogFooter,
  Button,
  Input,
  Label,
  RadioGroup,
  RadioGroupItem,
  DropdownMenu,
  DropdownMenuTrigger,
  DropdownMenuContent,
  DropdownMenuItem,
  Select,
  SelectContent,
  SelectItem,
  SelectTrigger,
  SelectValue,
  SortDirectionButton,
  Switch,
} from "@mochi/web";
import { Check, GripVertical, Minus, MoreHorizontal, Pencil, Plus, Trash2, X } from "lucide-react";
import type { CrmView, CrmField, CrmClass, FieldOption } from "@/types";
import { AddFieldDialog } from "./add-dialogs";
import { naturalCompare } from '@mochi/web'

// Pending field for create mode
export interface PendingField {
  id: string;
  name: string;
  fieldtype: string;
  flags?: string;
  rows?: number;
  options?: { name: string; colour: string }[];
}

// View Sheet (create + edit)
interface ViewSheetProps {
  open: boolean;
  onOpenChange: (open: boolean) => void;
  mode?: "create" | "edit";
  fields: CrmField[];
  classes: CrmClass[];
  // Edit mode props
  view?: CrmView | null;
  onUpdate?: (updates: Partial<CrmView>) => void;
  onUpdateClasses?: (classes: string[]) => void;
  onDelete?: () => void;
  // Create mode props
  onCreate?: (
    name: string,
    viewtype: string,
    columns: string,
    rows: string,
    selectedFields: string[],
    sort: string,
    direction: string,
    selectedClasses: string[],
    border: string
  ) => void | Promise<void>;
}

export function ViewSheet({
  open,
  onOpenChange,
  mode = "edit",
  fields,
  classes,
  view,
  onUpdate,
  onUpdateClasses,
  onDelete,
  onCreate,
}: ViewSheetProps) {
  const allClassIds = useMemo(() => classes.map((c) => c.id), [classes]);

  const [name, setName] = useState("");
  const [viewtype, setViewtype] = useState("board");
  const [columns, setColumns] = useState("");
  const [rows, setRows] = useState("");
  const [selectedFields, setSelectedFields] = useState<string[]>([]);
  const [sort, setSort] = useState("");
  const [direction, setDirection] = useState<"asc" | "desc">("asc");
  const [selectedClasses, setSelectedClasses] = useState<string[]>([]);
  const [border, setBorder] = useState("");
  const [draggedViewFieldId, setDraggedViewFieldId] = useState<string | null>(null);
  const [viewFieldDropIndicator, setViewFieldDropIndicator] = useState<{ fieldId: string; position: "before" | "after" } | null>(null);

  const enumeratedFields = fields.filter((f) => f.fieldtype === "enumerated");

  // Reset state on open
  useEffect(() => {
    if (!open) return;
    if (mode === "create") {
      setName("");
      setViewtype(enumeratedFields.length > 0 ? "board" : "list");
      setColumns(enumeratedFields[0]?.id || "");
      setRows("");
      setBorder("");
      setSelectedFields(fields.map((f) => f.id));
      setSort("");
      setDirection("asc");
      setSelectedClasses(classes.map((c) => c.id));
    } else if (view) {
      setName(view.name);
      setViewtype(view.viewtype);
      setColumns(view.columns || "");
      setRows(view.rows || "");
      setBorder(view.border || "");
      setSelectedFields((view.fields || "").split(",").filter(Boolean));
      setSort(view.sort || "");
      setDirection((view.direction as "asc" | "desc") || "asc");
      setSelectedClasses(view.classes?.length ? view.classes : allClassIds);
    }
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [open, view, mode]);

  if (mode === "edit" && !view) return null;

  // Edit mode handlers (live-save on change)
  const handleNameBlur = () => {
    if (mode === "edit" && onUpdate && view && name.trim() && name.trim() !== view.name) {
      onUpdate({ name: name.trim() });
    }
  };

  const handleViewtypeChange = (value: string) => {
    setViewtype(value);
    if (mode === "edit" && onUpdate && view && value !== view.viewtype) {
      onUpdate({ viewtype: value });
    }
  };

  const handleColumnsChange = (value: string) => {
    setColumns(value);
    if (mode === "edit" && onUpdate && view && value !== view.columns) {
      onUpdate({ columns: value });
    }
  };

  const handleRowsChange = (value: string) => {
    const v = value === "__none" ? "" : value;
    setRows(v);
    if (mode === "edit" && onUpdate && view && v !== view.rows) {
      onUpdate({ rows: v });
    }
  };

  const handleSortChange = (value: string) => {
    const v = value === "__none" ? "" : value;
    setSort(v);
    if (mode === "edit" && onUpdate && view && v !== view.sort) {
      onUpdate({ sort: v });
    }
  };

  const handleDirectionToggle = () => {
    const newDirection = direction === "asc" ? "desc" : "asc";
    setDirection(newDirection);
    if (mode === "edit" && onUpdate) {
      onUpdate({ direction: newDirection });
    }
  };

  const toggleViewField = (fieldId: string) => {
    let newFields: string[];
    if (selectedFields.includes(fieldId)) {
      newFields = selectedFields.filter((f) => f !== fieldId);
    } else {
      newFields = [...selectedFields, fieldId];
    }
    setSelectedFields(newFields);
    if (mode === "edit" && onUpdate) {
      onUpdate({ fields: newFields.join(",") });
    }
  };

  const handleViewFieldDragStart = (e: React.DragEvent, fieldId: string) => {
    setDraggedViewFieldId(fieldId);
    e.dataTransfer.effectAllowed = "move";
    e.dataTransfer.setData("text/plain", fieldId);
  };

  const handleViewFieldDragEnd = () => {
    setDraggedViewFieldId(null);
    setViewFieldDropIndicator(null);
  };

  const handleViewFieldDragOver = (e: React.DragEvent, fieldId: string) => {
    e.preventDefault();
    if (fieldId === draggedViewFieldId) return;
    const rect = e.currentTarget.getBoundingClientRect();
    const midY = rect.top + rect.height / 2;
    const position = e.clientY < midY ? "before" : "after";
    setViewFieldDropIndicator({ fieldId, position });
  };

  const handleViewFieldDrop = (e: React.DragEvent, targetFieldId: string) => {
    e.preventDefault();
    if (!draggedViewFieldId || draggedViewFieldId === targetFieldId) return;

    const draggedIndex = selectedFields.indexOf(draggedViewFieldId);
    const targetIndex = selectedFields.indexOf(targetFieldId);
    if (draggedIndex === -1 || targetIndex === -1) return;

    const newOrder = [...selectedFields];
    newOrder.splice(draggedIndex, 1);
    const insertIndex = viewFieldDropIndicator?.position === "after"
      ? targetIndex - (draggedIndex < targetIndex ? 1 : 0) + 1
      : targetIndex - (draggedIndex < targetIndex ? 1 : 0);
    newOrder.splice(insertIndex, 0, draggedViewFieldId);

    setSelectedFields(newOrder);
    if (mode === "edit" && onUpdate) {
      onUpdate({ fields: newOrder.join(",") });
    }

    setDraggedViewFieldId(null);
    setViewFieldDropIndicator(null);
  };

  const toggleClass = (classId: string) => {
    let newClasses: string[];
    if (selectedClasses.includes(classId)) {
      newClasses = selectedClasses.filter((c) => c !== classId);
    } else {
      newClasses = [...selectedClasses, classId];
    }
    setSelectedClasses(newClasses);
    if (mode === "edit" && onUpdateClasses) {
      onUpdateClasses(newClasses);
    }
  };

  const canSubmit = name.trim() && (viewtype !== "board" || enumeratedFields.length === 0 || columns);

  const handleCreate = async () => {
    if (onCreate && canSubmit) {
      try {
        await onCreate(name.trim(), viewtype, columns, rows, selectedFields, sort, direction, selectedClasses, border);
        onOpenChange(false);
      } catch {
        // Error displayed by caller via toast
      }
    }
  };

  return (
    <Sheet open={open} onOpenChange={onOpenChange}>
      <SheetContent className="w-full sm:max-w-md p-0 flex flex-col [&>button:last-child]:hidden">
        <div className="flex items-center justify-between px-6 py-4 border-b">
          <SheetTitle>{mode === "create" ? <Trans>Add view</Trans> : <Trans>Edit view</Trans>}</SheetTitle>
          <SheetDescription className="sr-only"><Trans>Configure view settings</Trans></SheetDescription>
          <div className="flex items-center gap-1">
            <Button variant="ghost" size="icon" className="size-8" onClick={() => onOpenChange(false)} aria-label={t`Close dialog`}>
              <X className="size-4" />
            </Button>
            {mode === "edit" && onDelete && (
              <DropdownMenu>
                <DropdownMenuTrigger asChild>
                  <Button variant="ghost" size="icon" className="size-8" aria-label={t`Open view actions`}>
                    <MoreHorizontal className="size-4" />
                  </Button>
                </DropdownMenuTrigger>
                <DropdownMenuContent align="end" onCloseAutoFocus={(e) => e.preventDefault()}>
                  <DropdownMenuItem onSelect={onDelete}>
                    <Minus className="size-4" />
                    <Trans>Delete view</Trans>
                  </DropdownMenuItem>
                </DropdownMenuContent>
              </DropdownMenu>
            )}
          </div>
        </div>
        <div className="flex-1 overflow-y-auto p-6 space-y-4">
          <div className="space-y-2">
            <Label htmlFor="view-name"><Trans>Name</Trans></Label>
            <div className="ps-4">
              <Input
                id="view-name"
                value={name}
                onChange={(e) => setName(e.target.value)}
                onBlur={mode === "edit" ? handleNameBlur : undefined}
                autoFocus={mode === "create"}
              />
            </div>
          </div>

          <div className="space-y-2">
            <Label><Trans>Layout</Trans></Label>
            <div className="ps-4">
              <RadioGroup value={viewtype} onValueChange={handleViewtypeChange}>
                <div className="flex items-center gap-2">
                  <RadioGroupItem value="board" id="vt-board" />
                  <Label htmlFor="vt-board" className="font-normal cursor-pointer">
                    <Trans>Board</Trans>
                  </Label>
                </div>
                <div className="flex items-center gap-2">
                  <RadioGroupItem value="list" id="vt-list" />
                  <Label htmlFor="vt-list" className="font-normal cursor-pointer">
                    <Trans>List</Trans>
                  </Label>
                </div>
              </RadioGroup>
            </div>
          </div>

          {classes.length > 1 && (
            <div className="space-y-2">
              <Label><Trans>Show classes</Trans></Label>
              <div className="ps-4 space-y-1">
                {classes.map((cls) => (
                  <label
                    key={cls.id}
                    className="flex items-center gap-2 text-sm cursor-pointer"
                  >
                    <Switch
                      checked={selectedClasses.includes(cls.id)}
                      onCheckedChange={() => toggleClass(cls.id)}
                    />
                    {cls.name}
                  </label>
                ))}
              </div>
            </div>
          )}

          {viewtype === "board" && enumeratedFields.length > 0 && (
            <div className="space-y-2">
              <Label><Trans>Columns group by</Trans></Label>
              <div className="ps-4">
                <Select value={columns} onValueChange={handleColumnsChange}>
                  <SelectTrigger className="w-full">
                    <SelectValue placeholder={t`Select a field`} />
                  </SelectTrigger>
                  <SelectContent>
                    {enumeratedFields.map((field) => (
                      <SelectItem key={field.id} value={field.id}>
                        {field.name}
                      </SelectItem>
                    ))}
                  </SelectContent>
                </Select>
              </div>
            </div>
          )}

          {viewtype === "board" && enumeratedFields.length > 0 && (
            <div className="space-y-2">
              <Label><Trans>Rows group by</Trans></Label>
              <div className="ps-4">
                <Select value={rows || "__none"} onValueChange={handleRowsChange}>
                  <SelectTrigger className="w-full">
                    <SelectValue placeholder={t`None`} />
                  </SelectTrigger>
                  <SelectContent>
                    <SelectItem value="__none"><Trans>None</Trans></SelectItem>
                    {enumeratedFields.map((field) => (
                      <SelectItem key={field.id} value={field.id}>
                        {field.name}
                      </SelectItem>
                    ))}
                  </SelectContent>
                </Select>
              </div>
            </div>
          )}

          {viewtype === "board" && enumeratedFields.length > 0 && (
            <div className="space-y-2">
              <Label><Trans>Border colour</Trans></Label>
              <div className="ps-4">
                <Select
                  value={border || "__none"}
                  onValueChange={(value) => {
                    const v = value === "__none" ? "" : value;
                    setBorder(v);
                    if (mode === "edit" && onUpdate) {
                      onUpdate({ border: v });
                    }
                  }}
                >
                  <SelectTrigger className="w-full">
                    <SelectValue placeholder={t`None`} />
                  </SelectTrigger>
                  <SelectContent>
                    <SelectItem value="__none"><Trans>None</Trans></SelectItem>
                    {enumeratedFields.map((field) => (
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
            <Label><Trans>Show fields</Trans></Label>
            <div className="ps-4 space-y-1">
              {selectedFields
                .map((id) => fields.find((f) => f.id === id))
                .filter(Boolean)
                .map((field) => (
                  <div key={field!.id}>
                    {viewFieldDropIndicator?.fieldId === field!.id && viewFieldDropIndicator.position === "before" && (
                      <div className="h-0.5 bg-primary mx-3 rounded-full" />
                    )}
                    <div
                      draggable
                      onDragStart={(e) => handleViewFieldDragStart(e, field!.id)}
                      onDragEnd={handleViewFieldDragEnd}
                      onDragOver={(e) => handleViewFieldDragOver(e, field!.id)}
                      onDragLeave={() => setViewFieldDropIndicator(null)}
                      onDrop={(e) => handleViewFieldDrop(e, field!.id)}
                      className={`flex items-center gap-2 px-3 py-1.5 text-sm rounded-md hover:bg-muted transition-colors cursor-grab ${
                        draggedViewFieldId === field!.id ? "opacity-50" : ""
                      }`}
                    >
                      <GripVertical className="size-4 text-muted-foreground shrink-0" />
                      <Switch
                        checked
                        onCheckedChange={() => toggleViewField(field!.id)}
                      />
                      {field!.name}
                    </div>
                    {viewFieldDropIndicator?.fieldId === field!.id && viewFieldDropIndicator.position === "after" && (
                      <div className="h-0.5 bg-primary mx-3 rounded-full" />
                    )}
                  </div>
                ))}
              {fields
                .filter((f) => !selectedFields.includes(f.id))
                .map((field) => (
                  <label
                    key={field.id}
                    className="flex items-center gap-2 px-3 py-1.5 text-sm cursor-pointer"
                  >
                    <Switch
                      checked={false}
                      onCheckedChange={() => toggleViewField(field.id)}
                    />
                    {field.name}
                  </label>
                ))}
            </div>
          </div>

          <div className="space-y-2">
            <Label><Trans>Default sort</Trans></Label>
            <div className="ps-4 flex gap-2">
              <Select value={sort || "__none"} onValueChange={handleSortChange}>
                <SelectTrigger className="flex-1">
                  <SelectValue placeholder={t`None`} />
                </SelectTrigger>
                <SelectContent>
                  <SelectItem value="__none"><Trans>None</Trans></SelectItem>
                  <SelectItem value="created"><Trans>Created</Trans></SelectItem>
                  <SelectItem value="number"><Trans>Number</Trans></SelectItem>
                  <SelectItem value="updated"><Trans>Updated</Trans></SelectItem>
                  {[...fields].sort((a, b) => naturalCompare(a.name, b.name)).map((field) => (
                    <SelectItem key={field.id} value={field.id}>
                      {field.name}
                    </SelectItem>
                  ))}
                </SelectContent>
              </Select>
              <SortDirectionButton
                direction={direction}
                onToggle={handleDirectionToggle}
              />
            </div>
          </div>
        </div>
        <SheetFooter className="px-6 py-4 border-t">
          {mode === "create" ? (
            <Button type="button" onClick={handleCreate} disabled={!canSubmit}>
              <Check className="size-4" />
              <Trans>Add view</Trans>
            </Button>
          ) : (
            <Button type="button" onClick={() => onOpenChange(false)}>
              <Check className="size-4" />
              <Trans>Done</Trans>
            </Button>
          )}
        </SheetFooter>
      </SheetContent>
    </Sheet>
  );
}

// Class Sheet (create + edit)
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
  const [pendingParents, setPendingParents] = useState<string[]>([""]);
  const [pendingFields, setPendingFields] = useState<PendingField[]>([]);
  const [addFieldOpen, setAddFieldOpen] = useState(false);

  // Reset state on open
  useEffect(() => {
    if (!open) return;
    if (mode === "create") {
      setName("");
      setPendingParents([]);
      setPendingFields([{ id: "title", name: "Title", fieldtype: "text", flags: "required,sort" }]);
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
      <SheetContent className="w-full sm:max-w-md p-0 flex flex-col [&>button:last-child]:hidden">
        <div className="flex items-center justify-between px-6 py-4 border-b">
          <SheetTitle>{mode === "create" ? <Trans>Add class</Trans> : <Trans>Edit class</Trans>}</SheetTitle>
          <SheetDescription className="sr-only"><Trans>Configure class settings</Trans></SheetDescription>
          <div className="flex items-center gap-1">
            <Button variant="ghost" size="icon" className="size-8" onClick={() => onOpenChange(false)} aria-label={t`Close dialog`}>
              <X className="size-4" />
            </Button>
            {mode === "edit" && onDelete && (
              <DropdownMenu>
                <DropdownMenuTrigger asChild>
                  <Button variant="ghost" size="icon" className="size-8" aria-label={t`Open class actions`}>
                    <MoreHorizontal className="size-4" />
                  </Button>
                </DropdownMenuTrigger>
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
              <Label htmlFor="class-id">ID</Label>
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
                  value={cls.title || "__none"}
                  onValueChange={(value) => {
                    if (onUpdate) {
                      onUpdate(cls.name, value === "__none" ? "" : value);
                    }
                  }}
                >
                  <SelectTrigger className="w-full">
                    <SelectValue placeholder={t`None`} />
                  </SelectTrigger>
                  <SelectContent>
                    <SelectItem value="__none"><Trans>None</Trans></SelectItem>
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
                      className={`flex items-center gap-2 px-3 py-2 text-sm rounded-md hover:bg-muted transition-colors cursor-grab ${
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
                        <Button
                          type="button"
                          variant="ghost"
                          size="icon"
                          className="size-6 shrink-0"
                          onClick={() => removePendingField(field.id)}
                          aria-label={t`Remove field ${field.name || field.id}`}
                          title={`Remove field ${field.name || field.id}`}
                        >
                          <X className="size-3" />
                        </Button>
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
interface EditFieldDialogProps {
  open: boolean;
  onOpenChange: (open: boolean) => void;
  field: CrmField | null;
  isSystemField?: boolean;
  options: FieldOption[];
  onUpdate: (updates: Partial<CrmField>) => void | Promise<void>;
  onDelete: () => void;
  onAddOption: () => void;
  onEditOption: (option: FieldOption) => void;
  onDeleteOption: (optionId: string) => void;
  onReorderOptions: (order: string[]) => void;
}

export function EditFieldDialog({
  open,
  onOpenChange,
  field,
  isSystemField: isSystemFieldProp,
  options,
  onUpdate,
  onDelete,
  onAddOption,
  onEditOption,
  onDeleteOption,
}: EditFieldDialogProps) {
  const [name, setName] = useState("");
  const [fieldId, setFieldId] = useState("");
  const [rows, setRows] = useState(1);

  useEffect(() => {
    if (field) {
      setName(field.name);
      setFieldId(field.id);
      setRows(field.rows || 1);
    }
  // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [field?.id]);

  if (!field) return null;

  const isSystemField = isSystemFieldProp ?? false;

  const handleNameBlur = () => {
    if (name.trim() && name.trim() !== field.name) {
      onUpdate({ name: name.trim() });
    }
  };

  const handleIdBlur = async () => {
    const trimmed = fieldId.trim().toLowerCase();
    if (trimmed && trimmed !== field.id) {
      try {
        await onUpdate({ id: trimmed } as Partial<CrmField>);
      } catch {
        setFieldId(field.id);
      }
    }
  };

  const handleRowsBlur = () => {
    if (field.fieldtype === "text" && rows !== (field.rows || 1)) {
      onUpdate({ rows });
    }
  };

  const hasFlag = (flag: string) => {
    return (field.flags || "").split(",").filter(Boolean).includes(flag);
  };

  const toggleFlag = (flag: string, checked: boolean) => {
    const current = (field.flags || "").split(",").filter(Boolean);
    const updated = checked
      ? [...current, flag]
      : current.filter((f) => f !== flag);
    onUpdate({ flags: updated.join(",") } as Partial<typeof field>);
  };

  return (
    <ResponsiveDialog open={open} onOpenChange={onOpenChange}>
      <ResponsiveDialogContent className="max-w-md flex flex-col max-h-[85vh]" showCloseButton={false}>
        <ResponsiveDialogHeader>
          <ResponsiveDialogTitle><Trans>Edit field</Trans></ResponsiveDialogTitle>
          <ResponsiveDialogDescription className="sr-only"><Trans>Edit field settings</Trans></ResponsiveDialogDescription>
        </ResponsiveDialogHeader>
        <div className="flex-1 overflow-y-auto p-6 space-y-4">
          <div className="space-y-2">
            <Label htmlFor="field-name"><Trans>Name</Trans></Label>
            <Input
              id="field-name"
              value={name}
              onChange={(e) => setName(e.target.value)}
              onBlur={handleNameBlur}
            />
          </div>

          <div className="space-y-2">
            <Label htmlFor="field-id">ID</Label>
            <Input
              id="field-id"
              value={fieldId}
              onChange={(e) => setFieldId(e.target.value.toLowerCase().replace(/[^a-z0-9_]/g, ""))}
              onBlur={handleIdBlur}
            />
          </div>

          <div className="space-y-2">
            <Label><Trans>Type</Trans></Label>
            <p className="text-sm text-muted-foreground capitalize">{field.fieldtype}</p>
          </div>

          {field.fieldtype === "text" && (
            <div className="space-y-2">
              <Label htmlFor="field-rows"><Trans>Rows</Trans></Label>
              <Input
                id="field-rows"
                type="number"
                min={1}
                max={20}
                value={rows}
                onChange={(e) => setRows(parseInt(e.target.value) || 1)}
                onBlur={handleRowsBlur}
              />
              <p className={`text-xs text-muted-foreground ${rows === 1 ? "" : "invisible"}`}>
                <Trans>Single line of text only</Trans>
              </p>
            </div>
          )}

          <div className="space-y-2">
            <Label><Trans>Flags</Trans></Label>
            <div className="ps-4 space-y-2">
              {[
                { id: "required", label: <Trans>Required</Trans> },
                { id: "sort", label: <Trans>Allow sort by</Trans> },
              ].map((flag) => (
                <label key={flag.id} className="flex items-center gap-2 text-sm cursor-pointer">
                  <Switch
                    checked={hasFlag(flag.id)}
                    onCheckedChange={(checked) => toggleFlag(flag.id, checked)}
                  />
                  {flag.label}
                </label>
              ))}
            </div>
          </div>

          {field.fieldtype === "enumerated" && (
            <div className="space-y-2">
              <Label><Trans>Options</Trans></Label>
              <div className="space-y-1">
                {options.map((opt) => (
                  <div
                    key={opt.id}
                    className="flex items-center justify-between p-2 border rounded"
                  >
                    <div className="flex items-center gap-2">
                      <span
                        className="size-3 rounded-full"
                        style={{ backgroundColor: opt.colour }}
                      />
                      <span className="text-sm">{opt.name}</span>
                    </div>
                    <div className="flex gap-1">
                      <Button
                        type="button"
                        variant="ghost"
                        size="icon"
                        className="size-7"
                        onClick={() => onEditOption(opt)}
                        aria-label={t`Edit option ${opt.name}`}
                        title={`Edit option ${opt.name}`}
                      >
                        <Pencil className="size-3.5" />
                      </Button>
                      <Button
                        type="button"
                        variant="ghost"
                        size="icon"
                        className="size-7"
                        onClick={() => onDeleteOption(opt.id)}
                        aria-label={t`Delete option ${opt.name}`}
                        title={`Delete option ${opt.name}`}
                      >
                        <Trash2 className="size-3.5" />
                      </Button>
                    </div>
                  </div>
                ))}
              </div>
              <Button type="button" variant="outline" size="sm" onClick={onAddOption}>
                <Trans>Add option</Trans>
              </Button>
            </div>
          )}
        </div>
        <ResponsiveDialogFooter className="justify-between">
          {!isSystemField ? (
            <Button type="button" variant="outline" onClick={onDelete}>
              <Minus className="size-4" />
              <Trans>Delete field</Trans>
            </Button>
          ) : <div />}
          <Button type="button" onClick={() => onOpenChange(false)}>
            <Check className="size-4" />
            <Trans>Done</Trans>
          </Button>
        </ResponsiveDialogFooter>
      </ResponsiveDialogContent>
    </ResponsiveDialog>
  );
}
