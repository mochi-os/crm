// Mochi CRMs: Keyboard shortcuts help dialog
// Copyright Alistair Cunningham 2026

import {
  Dialog,
  DialogContent,
  DialogHeader,
  DialogTitle,
} from "@mochi/common";

interface KeyboardShortcutsHelpProps {
  open: boolean;
  onOpenChange: (open: boolean) => void;
}

const isMac = typeof navigator !== "undefined" && navigator.platform.includes("Mac");

const shortcuts = [
  { key: "c / n", description: "Create new item" },
  { key: isMac ? "⌘ K" : "Ctrl+K", description: "Toggle view options" },
  { key: "1-9", description: "Switch to view 1-9" },
  { key: "j / ↓", description: "Select next card" },
  { key: "k / ↑", description: "Select previous card" },
  { key: "Enter", description: "Open selected card" },
  { key: "e", description: "Edit selected card" },
  { key: "Escape", description: "Close panel / cancel" },
  { key: "?", description: "Show this help" },
];

export function KeyboardShortcutsHelp({
  open,
  onOpenChange,
}: KeyboardShortcutsHelpProps) {
  return (
    <Dialog open={open} onOpenChange={onOpenChange}>
      <DialogContent className="max-w-md">
        <DialogHeader>
          <DialogTitle>Keyboard shortcuts</DialogTitle>
        </DialogHeader>
        <div className="space-y-1">
          {shortcuts.map((shortcut) => (
            <div
              key={shortcut.key}
              className="flex items-center justify-between py-1.5"
            >
              <span className="text-sm text-muted-foreground">
                {shortcut.description}
              </span>
              <kbd className="bg-muted text-muted-foreground rounded px-2 py-1 text-xs font-mono">
                {shortcut.key}
              </kbd>
            </div>
          ))}
        </div>
      </DialogContent>
    </Dialog>
  );
}
