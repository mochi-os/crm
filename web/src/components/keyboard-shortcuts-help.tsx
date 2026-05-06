// Mochi CRMs: Keyboard shortcuts help dialog
// Copyright Alistair Cunningham 2026

import {
  ResponsiveDialog,
  ResponsiveDialogContent,
  ResponsiveDialogDescription,
  ResponsiveDialogHeader,
  ResponsiveDialogTitle,
} from "@mochi/web";

import { Trans, useLingui } from '@lingui/react/macro'
interface KeyboardShortcutsHelpProps {
  open: boolean;
  onOpenChange: (open: boolean) => void;
}

const isMac = typeof navigator !== "undefined" && navigator.platform.includes("Mac");

function useShortcuts() {
  const { t } = useLingui();
  /* eslint-disable lingui/no-unlocalized-strings */
  return [
    { key: "c / n", description: t`Create new item` },
    { key: isMac ? "⌘ K" : "Ctrl+K", description: t`Toggle view options` },
    { key: "1-9", description: t`Switch to view 1-9` },
    { key: "j / ↓", description: t`Select next card` },
    { key: "k / ↑", description: t`Select previous card` },
    { key: "Enter", description: t`Open selected card` },
    { key: "e", description: t`Edit selected card` },
    { key: "Escape", description: t`Close panel / cancel` },
    { key: "?", description: t`Show this help` },
  ];
  /* eslint-enable lingui/no-unlocalized-strings */
}

export function KeyboardShortcutsHelp({
  open,
  onOpenChange,
}: KeyboardShortcutsHelpProps) {
  const shortcuts = useShortcuts();
  return (
    <ResponsiveDialog open={open} onOpenChange={onOpenChange}>
      <ResponsiveDialogContent className="max-w-md">
        <ResponsiveDialogHeader>
          <ResponsiveDialogTitle><Trans>Keyboard shortcuts</Trans></ResponsiveDialogTitle>
          <ResponsiveDialogDescription className="sr-only"><Trans>Available keyboard shortcuts</Trans></ResponsiveDialogDescription>
        </ResponsiveDialogHeader>
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
      </ResponsiveDialogContent>
    </ResponsiveDialog>
  );
}
