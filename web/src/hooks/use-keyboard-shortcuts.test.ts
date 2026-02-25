// Tests for keyboard shortcuts hook
import { describe, it, expect, vi, beforeEach, afterEach } from "vitest";
import { renderHook } from "@testing-library/react";
import { useKeyboardShortcuts } from "./use-keyboard-shortcuts";

describe("useKeyboardShortcuts", () => {
  const defaultCallbacks = {
    onCreateNew: vi.fn(),
    onFocusSearch: vi.fn(),
    onSwitchView: vi.fn(),
    onSelectNext: vi.fn(),
    onSelectPrevious: vi.fn(),
    onOpenSelected: vi.fn(),
    onEditSelected: vi.fn(),
    onClose: vi.fn(),
    onShowHelp: vi.fn(),
  };

  beforeEach(() => {
    vi.clearAllMocks();
  });

  afterEach(() => {
    vi.restoreAllMocks();
  });

  const fireKeydown = (key: string, options: Partial<KeyboardEvent> = {}) => {
    const event = new KeyboardEvent("keydown", {
      key,
      bubbles: true,
      ...options,
    });
    window.dispatchEvent(event);
  };

  it("should call onCreateNew when 'c' is pressed", () => {
    renderHook(() => useKeyboardShortcuts(defaultCallbacks));

    fireKeydown("c");

    expect(defaultCallbacks.onCreateNew).toHaveBeenCalledTimes(1);
  });

  it("should call onFocusSearch when Ctrl+K is pressed", () => {
    renderHook(() => useKeyboardShortcuts(defaultCallbacks));

    fireKeydown("k", { ctrlKey: true });

    expect(defaultCallbacks.onFocusSearch).toHaveBeenCalledTimes(1);
  });

  it("should call onFocusSearch when Cmd+K is pressed", () => {
    renderHook(() => useKeyboardShortcuts(defaultCallbacks));

    fireKeydown("k", { metaKey: true });

    expect(defaultCallbacks.onFocusSearch).toHaveBeenCalledTimes(1);
  });

  it("should call onSelectNext when 'j' is pressed", () => {
    renderHook(() => useKeyboardShortcuts(defaultCallbacks));

    fireKeydown("j");

    expect(defaultCallbacks.onSelectNext).toHaveBeenCalledTimes(1);
  });

  it("should call onSelectPrevious when 'k' is pressed", () => {
    renderHook(() => useKeyboardShortcuts(defaultCallbacks));

    fireKeydown("k");

    expect(defaultCallbacks.onSelectPrevious).toHaveBeenCalledTimes(1);
  });

  it("should call onOpenSelected when Enter is pressed", () => {
    renderHook(() => useKeyboardShortcuts(defaultCallbacks));

    fireKeydown("Enter");

    expect(defaultCallbacks.onOpenSelected).toHaveBeenCalledTimes(1);
  });

  it("should call onClose when Escape is pressed", () => {
    renderHook(() => useKeyboardShortcuts(defaultCallbacks));

    fireKeydown("Escape");

    expect(defaultCallbacks.onClose).toHaveBeenCalledTimes(1);
  });

  it("should call onShowHelp when '?' is pressed", () => {
    renderHook(() => useKeyboardShortcuts(defaultCallbacks));

    fireKeydown("?");

    expect(defaultCallbacks.onShowHelp).toHaveBeenCalledTimes(1);
  });

  it("should call onSwitchView with view index when number is pressed", () => {
    renderHook(() => useKeyboardShortcuts(defaultCallbacks));

    fireKeydown("1");
    expect(defaultCallbacks.onSwitchView).toHaveBeenCalledWith(0);

    fireKeydown("2");
    expect(defaultCallbacks.onSwitchView).toHaveBeenCalledWith(1);

    fireKeydown("3");
    expect(defaultCallbacks.onSwitchView).toHaveBeenCalledWith(2);
  });

  it("should not fire shortcuts when disabled", () => {
    renderHook(() =>
      useKeyboardShortcuts({
        ...defaultCallbacks,
        enabled: false,
      }),
    );

    fireKeydown("c");
    fireKeydown("/");
    fireKeydown("j");

    expect(defaultCallbacks.onCreateNew).not.toHaveBeenCalled();
    expect(defaultCallbacks.onFocusSearch).not.toHaveBeenCalled();
    expect(defaultCallbacks.onSelectNext).not.toHaveBeenCalled();
  });

  it("should not fire shortcuts when typing in input", () => {
    renderHook(() => useKeyboardShortcuts(defaultCallbacks));

    // Create and focus an input element
    const input = document.createElement("input");
    document.body.appendChild(input);
    input.focus();

    // Dispatch event from the input element (bubbles up to window)
    const event = new KeyboardEvent("keydown", {
      key: "c",
      bubbles: true,
    });
    input.dispatchEvent(event);

    // Should not have been called because target is an input
    expect(defaultCallbacks.onCreateNew).not.toHaveBeenCalled();

    document.body.removeChild(input);
  });

  it("should cleanup event listeners on unmount", () => {
    const removeEventListenerSpy = vi.spyOn(window, "removeEventListener");

    const { unmount } = renderHook(() =>
      useKeyboardShortcuts(defaultCallbacks),
    );

    unmount();

    expect(removeEventListenerSpy).toHaveBeenCalledWith(
      "keydown",
      expect.any(Function),
    );
  });
});
