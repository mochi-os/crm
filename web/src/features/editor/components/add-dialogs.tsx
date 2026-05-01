// Mochi CRMs: Add dialogs for design editor
// Copyright Alistair Cunningham 2026

import { useState } from "react";
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
  Select,
  SelectContent,
  SelectItem,
  SelectTrigger,
  SelectValue,
  PRESET_COLOURS,
} from "@mochi/web";
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
          <SheetTitle><Trans>Add field</Trans></SheetTitle>
          <SheetDescription className="sr-only"><Trans>Add a new field to this class</Trans></SheetDescription>
          <Button variant="ghost" size="icon" className="size-8" onClick={handleClose}>
            <X className="size-4" />
          </Button>
        </div>
        <div className="flex-1 overflow-y-auto p-6 space-y-4">
          <div className="space-y-2">
            <Label htmlFor="field-name"><Trans>Name</Trans></Label>
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
            <Label htmlFor="field-type"><Trans>Type</Trans></Label>
            <div className="pl-4">
              <Select value={fieldtype} onValueChange={setFieldtype}>
                <SelectTrigger id="field-type" className="w-full">
                  <SelectValue />
                </SelectTrigger>
                <SelectContent>
                  <SelectItem value="checkbox"><Trans>Checkbox</Trans></SelectItem>
                  <SelectItem value="checklist"><Trans>Checklist</Trans></SelectItem>
                  <SelectItem value="date"><Trans>Date</Trans></SelectItem>
                  <SelectItem value="number"><Trans>Number</Trans></SelectItem>
                  <SelectItem value="enumerated"><Trans>Select</Trans></SelectItem>
                  <SelectItem value="text"><Trans>Text</Trans></SelectItem>
                  <SelectItem value="user"><Trans>User</Trans></SelectItem>
                </SelectContent>
              </Select>
            </div>
          </div>
          {fieldtype === "text" && (
            <div className="space-y-2">
              <Label htmlFor="field-rows"><Trans>Rows</Trans></Label>
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
                  <Trans>Single line of text only</Trans>
                </p>
              </div>
            </div>
          )}
          {fieldtype === "enumerated" && (
            <div className="space-y-2">
              <Label><Trans>Options</Trans></Label>
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
                          <Trans>Remove</Trans>
                        </Button>
                      </div>
                    ))}
                  </div>
                )}
                <div className="flex gap-2">
                  <Input
                    value={newOptionName}
                    onChange={(e) => setNewOptionName(e.target.value)}
                    placeholder={t`Option name`}
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
            <Trans>Add field</Trans>
          </Button>
        </SheetFooter>
      </SheetContent>
    </Sheet>
  );
}
