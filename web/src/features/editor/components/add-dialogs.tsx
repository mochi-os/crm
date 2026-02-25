// Mochi CRMs: Add dialogs for design editor
// Copyright Alistair Cunningham 2026

import { useState } from "react";
import {
  Sheet,
  SheetContent,
  SheetTitle,
  SheetFooter,
  Button,
  Input,
  Label,
  PRESET_COLOURS,
} from "@mochi/common";
import { Check, Plus, X } from "lucide-react";

// Add Field Dialog
interface PendingOption {
  id: string;
  name: string;
  colour: string;
}

interface AddFieldDialogProps {
  open: boolean;
  onOpenChange: (open: boolean) => void;
  onAdd: (name: string, fieldtype: string, rows?: number, options?: PendingOption[]) => void | Promise<void>;
}

const FIELD_TYPES = [
  { id: "checkbox", name: "Checkbox" },
  { id: "checklist", name: "Checklist" },
  { id: "date", name: "Date" },
  { id: "number", name: "Number" },
  { id: "enumerated", name: "Select" },
  { id: "text", name: "Text" },
  { id: "user", name: "User" },
];

export function AddFieldDialog({
  open,
  onOpenChange,
  onAdd,
}: AddFieldDialogProps) {
  const [name, setName] = useState("");
  const [fieldtype, setFieldtype] = useState("text");
  const [rows, setRows] = useState(1);
  const [options, setOptions] = useState<PendingOption[]>([]);
  const [newOptionName, setNewOptionName] = useState("");

  const resetForm = () => {
    setName("");
    setFieldtype("text");
    setRows(1);
    setOptions([]);
    setNewOptionName("");
  };

  const handleSubmit = async () => {
    if (name.trim()) {
      await onAdd(
        name.trim(),
        fieldtype,
        fieldtype === "text" && rows > 1 ? rows : undefined,
        fieldtype === "enumerated" ? options : undefined
      );
      resetForm();
      onOpenChange(false);
    }
  };

  const addOption = () => {
    if (newOptionName.trim()) {
      setOptions([
        ...options,
        {
          id: crypto.randomUUID(),
          name: newOptionName.trim(),
          colour: PRESET_COLOURS[options.length % PRESET_COLOURS.length],
        },
      ]);
      setNewOptionName("");
    }
  };

  const removeOption = (id: string) => {
    setOptions(options.filter((o) => o.id !== id));
  };

  const handleClose = () => {
    resetForm();
    onOpenChange(false);
  };

  return (
    <Sheet open={open} onOpenChange={handleClose}>
      <SheetContent className="w-full sm:max-w-md p-0 flex flex-col [&>button:last-child]:hidden">
        <div className="flex items-center justify-between px-6 py-4 border-b">
          <SheetTitle>Add field</SheetTitle>
          <Button variant="ghost" size="icon" className="size-8" onClick={handleClose}>
            <X className="size-4" />
          </Button>
        </div>
        <div className="flex-1 overflow-y-auto p-6 space-y-4">
          <div className="space-y-2">
            <Label htmlFor="field-name">Name</Label>
            <div className="pl-4">
              <Input
                id="field-name"
                value={name}
                onChange={(e) => setName(e.target.value)}

                autoFocus
              />
            </div>
          </div>
          <div className="space-y-2">
            <Label htmlFor="field-type">Type</Label>
            <div className="pl-4">
              <select
                id="field-type"
                value={fieldtype}
                onChange={(e) => setFieldtype(e.target.value)}
                className="w-full h-9 rounded-md border border-input bg-background px-3 py-1 text-sm"
              >
                {FIELD_TYPES.map((ft) => (
                  <option key={ft.id} value={ft.id}>
                    {ft.name}
                  </option>
                ))}
              </select>
            </div>
          </div>
          {fieldtype === "text" && (
            <div className="space-y-2">
              <Label htmlFor="field-rows">Rows</Label>
              <div className="pl-4">
                <Input
                  id="field-rows"
                  type="number"
                  min={1}
                  max={20}
                  value={rows}
                  onChange={(e) => setRows(parseInt(e.target.value) || 1)}
                />
                <p className={`text-xs text-muted-foreground mt-1 ${rows === 1 ? "" : "invisible"}`}>
                  Single line of text only
                </p>
              </div>
            </div>
          )}
          {fieldtype === "enumerated" && (
            <div className="space-y-2">
              <Label>Options</Label>
              <div className="pl-4 space-y-2">
                {options.length > 0 && (
                  <div className="space-y-1">
                    {options.map((opt) => (
                      <div
                        key={opt.id}
                        className="flex items-center justify-between p-2 border rounded-md"
                      >
                        <div className="flex items-center gap-2">
                          <span
                            className="size-3 rounded-full"
                            style={{ backgroundColor: opt.colour }}
                          />
                          <span className="text-sm">{opt.name}</span>
                        </div>
                        <Button
                          type="button"
                          variant="ghost"
                          size="sm"
                          onClick={() => removeOption(opt.id)}
                        >
                          Remove
                        </Button>
                      </div>
                    ))}
                  </div>
                )}
                <div className="flex gap-2">
                  <Input
                    value={newOptionName}
                    onChange={(e) => setNewOptionName(e.target.value)}
                    placeholder="Option name"
                    onKeyDown={(e) => {
                      if (e.key === "Enter") {
                        e.preventDefault();
                        addOption();
                      }
                    }}
                  />
                  <Button
                    type="button"
                    variant="outline"
                    onClick={addOption}
                    disabled={!newOptionName.trim()}
                  >
                    <Plus className="size-4" />
                  </Button>
                </div>
              </div>
            </div>
          )}
        </div>
        <SheetFooter className="px-6 py-4 border-t">
          <Button
            onClick={handleSubmit}
            disabled={!name.trim() || (fieldtype === "enumerated" && options.length === 0)}
          >
            <Check className="size-4" />
            Add field
          </Button>
        </SheetFooter>
      </SheetContent>
    </Sheet>
  );
}

