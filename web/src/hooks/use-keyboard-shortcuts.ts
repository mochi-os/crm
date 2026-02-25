// Mochi CRMs: Keyboard shortcuts hook
// Copyright Alistair Cunningham 2026

import { useEffect, useCallback } from "react";

interface KeyboardShortcutsOptions {
  onCreateNew?: () => void;
  onFocusSearch?: () => void;
  onSwitchView?: (viewIndex: number) => void;
  onSelectNext?: () => void;
  onSelectPrevious?: () => void;
  onOpenSelected?: () => void;
  onEditSelected?: () => void;
  onClose?: () => void;
  onShowHelp?: () => void;
  enabled?: boolean;
}

export function useKeyboardShortcuts({
  onCreateNew,
  onFocusSearch,
  onSwitchView,
  onSelectNext,
  onSelectPrevious,
  onOpenSelected,
  onEditSelected,
  onClose,
  onShowHelp,
  enabled = true,
}: KeyboardShortcutsOptions) {
  const handleKeyDown = useCallback(
    (e: KeyboardEvent) => {
      // Don't handle shortcuts when typing in inputs
      const target = e.target as HTMLElement;
      const isInput =
        target.tagName === "INPUT" ||
        target.tagName === "TEXTAREA" ||
        target.isContentEditable;

      // Always handle Escape
      if (e.key === "Escape") {
        onClose?.();
        return;
      }

      // Handle Cmd+K even in inputs
      if ((e.metaKey || e.ctrlKey) && e.key === "k") {
        e.preventDefault();
        onFocusSearch?.();
        return;
      }

      // Don't handle other shortcuts in inputs
      if (isInput) return;

      switch (e.key) {
        case "c":
        case "n":
          e.preventDefault();
          onCreateNew?.();
          break;
        case "?":
          e.preventDefault();
          onShowHelp?.();
          break;
        case "j":
        case "ArrowDown":
          e.preventDefault();
          onSelectNext?.();
          break;
        case "k":
        case "ArrowUp":
          e.preventDefault();
          onSelectPrevious?.();
          break;
        case "Enter":
          e.preventDefault();
          onOpenSelected?.();
          break;
        case "e":
          e.preventDefault();
          onEditSelected?.();
          break;
        case "1":
        case "2":
        case "3":
        case "4":
        case "5":
        case "6":
        case "7":
        case "8":
        case "9":
          e.preventDefault();
          onSwitchView?.(parseInt(e.key) - 1);
          break;
      }
    },
    [
      onCreateNew,
      onFocusSearch,
      onSwitchView,
      onSelectNext,
      onSelectPrevious,
      onOpenSelected,
      onEditSelected,
      onClose,
      onShowHelp,
    ],
  );

  // Handle Ctrl+K in capture phase to intercept before other handlers
  const handleCtrlK = useCallback(
    (e: KeyboardEvent) => {
      if ((e.metaKey || e.ctrlKey) && e.key === "k") {
        e.preventDefault();
        e.stopPropagation();
        onFocusSearch?.();
      }
    },
    [onFocusSearch],
  );

  useEffect(() => {
    if (!enabled) return;

    // Use capture phase for Ctrl+K to intercept before SearchProvider
    document.addEventListener("keydown", handleCtrlK, true);
    window.addEventListener("keydown", handleKeyDown);
    return () => {
      document.removeEventListener("keydown", handleCtrlK, true);
      window.removeEventListener("keydown", handleKeyDown);
    };
  }, [enabled, handleKeyDown, handleCtrlK]);
}
