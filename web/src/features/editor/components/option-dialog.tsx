// Mochi CRMs: Unified option dialog (add + edit modes)
// Copyright Alistair Cunningham 2026

import { useState, useEffect } from "react";
import {
  Dialog,
  DialogContent,
  DialogHeader,
  DialogTitle,
  DialogFooter,
  Button,
  Input,
  Label,
  ColourPicker,
  PRESET_COLOURS,
  DropdownMenu,
  DropdownMenuTrigger,
  DropdownMenuContent,
  DropdownMenuItem,
} from "@mochi/common";
import { Minus, MoreHorizontal } from "lucide-react";
import type { FieldOption } from "@/types";

interface OptionDialogProps {
  open: boolean;
  onOpenChange: (open: boolean) => void;
  title?: string;
  option?: FieldOption | null;
  onUpdate?: (updates: { name?: string; colour?: string }) => void;
  onDelete?: () => void;
  onAdd?: (name: string, colour: string) => void | Promise<void>;
}

export function OptionDialog({
  open,
  onOpenChange,
  title,
  option,
  onUpdate,
  onDelete,
  onAdd,
}: OptionDialogProps) {
  const isEdit = !!option;
  const [name, setName] = useState("");
  const [colour, setColour] = useState(PRESET_COLOURS[1]);

  useEffect(() => {
    if (!open) return;
    if (option) {
      setName(option.name);
      setColour(option.colour);
    } else {
      setName("");
      setColour(PRESET_COLOURS[Math.floor(Math.random() * PRESET_COLOURS.length)]);
    }
  }, [open, option]);

  const handleAdd = async () => {
    if (name.trim() && onAdd) {
      await onAdd(name.trim(), colour);
      onOpenChange(false);
    }
  };

  const handleSave = () => {
    if (option && onUpdate) {
      if (name.trim() !== option.name || colour !== option.colour) {
        onUpdate({ name: name.trim(), colour });
      }
    }
    onOpenChange(false);
  };

  return (
    <Dialog open={open} onOpenChange={onOpenChange}>
      <DialogContent showCloseButton={false}>
        <DialogHeader className="flex flex-row items-center justify-between">
          <DialogTitle>{title || (isEdit ? "Edit option" : "Add option")}</DialogTitle>
          {isEdit && onDelete && (
            <DropdownMenu>
              <DropdownMenuTrigger asChild>
                <Button variant="ghost" size="icon" className="size-8">
                  <MoreHorizontal className="size-4" />
                </Button>
              </DropdownMenuTrigger>
              <DropdownMenuContent align="end">
                <DropdownMenuItem onClick={onDelete}>
                  <Minus className="size-4" />
                  Delete option
                </DropdownMenuItem>
              </DropdownMenuContent>
            </DropdownMenu>
          )}
        </DialogHeader>
        <div className="py-4 space-y-4">
          <div className="space-y-2">
            <Label htmlFor="option-name">Name</Label>
            <Input
              id="option-name"
              value={name}
              onChange={(e) => setName(e.target.value)}
              autoFocus
              onKeyDown={(e) => {
                if (e.key === "Enter" && name.trim()) {
                  e.preventDefault();
                  isEdit ? handleSave() : handleAdd();
                }
              }}
            />
          </div>
          <div className="space-y-2">
            <Label>Colour</Label>
            <ColourPicker value={colour} onChange={setColour} />
          </div>
          <div className="flex items-center gap-2">
            <span
              className="size-4 rounded-full"
              style={{ backgroundColor: colour }}
            />
            <span className="text-sm">{name || "Option name"}</span>
          </div>
        </div>
        <DialogFooter>
          {isEdit ? (
            <>
              <Button type="button" variant="outline" onClick={() => onOpenChange(false)}>
                Cancel
              </Button>
              <Button type="button" onClick={handleSave}>
                Save
              </Button>
            </>
          ) : (
            <Button type="button" onClick={handleAdd} disabled={!name.trim()}>
              Add option
            </Button>
          )}
        </DialogFooter>
      </DialogContent>
    </Dialog>
  );
}
