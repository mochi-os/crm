// Mochi CRMs: Field editor component
// Copyright Alistair Cunningham 2026

import { useState, useEffect, useRef } from "react";
import {
  Button,
  Switch,
  Input,
  Textarea,
  Select,
  SelectContent,
  SelectItem,
  SelectTrigger,
  SelectValue,
  PersonPicker,
  type Person,
} from "@mochi/common";
import { Plus, Trash2 } from "lucide-react";
import type { CrmField, FieldOption, ChecklistItem } from "@/types";

interface FieldEditorProps {
  field: CrmField;
  value: string;
  options: FieldOption[];
  onChange: (value: string) => void;
  disabled?: boolean;
  readOnly?: boolean;
  autoFocus?: boolean;
  immediate?: boolean;
  localPeople?: Person[];
  onValidationError?: (hasError: boolean) => void;
}

export function FieldEditor({
  field,
  value,
  options,
  onChange,
  disabled,
  readOnly,
  hideLabel,
  autoFocus,
  immediate,
  localPeople = [],
  onValidationError,
}: FieldEditorProps & { hideLabel?: boolean }) {
  const [localValue, setLocalValue] = useState(value);
  const debounceTimerRef = useRef<NodeJS.Timeout | null>(null);
  const focusedRef = useRef(false);
  const localValueRef = useRef(value);
  const onChangeRef = useRef(onChange);
  onChangeRef.current = onChange;

  // Sync local state with prop value when it changes externally,
  // but not while the user is actively editing (focused)
  useEffect(() => {
    if (!focusedRef.current) {
      setLocalValue(value);
      localValueRef.current = value;
    }
  }, [value]);

  const handleFocus = () => {
    focusedRef.current = true;
  };

  const handleBlur = () => {
    focusedRef.current = false;
    if (debounceTimerRef.current) {
      clearTimeout(debounceTimerRef.current);
      debounceTimerRef.current = null;
    }
    onChangeRef.current(localValueRef.current);
  };

  const handleTextChange = (newValue: string) => {
    setLocalValue(newValue);
    localValueRef.current = newValue;

    if (immediate) {
      onChangeRef.current(newValue);
      return;
    }

    // Debounce auto-save for better UX
    if (debounceTimerRef.current) {
      clearTimeout(debounceTimerRef.current);
    }

    debounceTimerRef.current = setTimeout(() => {
      onChangeRef.current(localValueRef.current);
    }, 1000); // 1 second debounce
  };

  // Read-only display: render values as plain text with normal styling
  const renderDisplay = () => {
    switch (field.fieldtype) {
      case "enumerated": {
        const opt = options.find((o) => o.id === value);
        if (!opt) return <span className="text-sm text-muted-foreground">—</span>;
        return (
          <div className="flex items-center gap-2 h-9 text-sm">
            {opt.colour && (
              <div className="w-3 h-3 rounded-full shrink-0" style={{ backgroundColor: opt.colour }} />
            )}
            {opt.name}
          </div>
        );
      }
      case "text":
        if (!value) return <span className="text-sm text-muted-foreground h-9 flex items-center">—</span>;
        if (field.rows > 1) return <p className="text-sm whitespace-pre-wrap pt-2">{value}</p>;
        return <span className="text-sm h-9 flex items-center">{value}</span>;
      case "number":
        if (!value) return <span className="text-sm text-muted-foreground h-9 flex items-center">—</span>;
        return <span className="text-sm h-9 flex items-center">{value}</span>;
      case "date":
        if (!value) return <span className="text-sm text-muted-foreground h-9 flex items-center">—</span>;
        return <span className="text-sm h-9 flex items-center">{new Date(value + "T00:00:00").toLocaleDateString()}</span>;
      case "user": {
        const person = localPeople.find((p) => p.id === value);
        if (!person) return <span className="text-sm text-muted-foreground h-9 flex items-center">—</span>;
        return <span className="text-sm h-9 flex items-center">{person.name}</span>;
      }
      case "checkbox":
        return (
          <div className="pt-2">
            <Switch checked={value === "1" || value === "true"} disabled />
          </div>
        );
      case "checklist": {
        const items: ChecklistItem[] = (() => {
          if (!value) return [];
          try { return JSON.parse(value); } catch { return []; }
        })();
        if (items.length === 0) return <span className="text-sm text-muted-foreground">—</span>;
        const doneCount = items.filter((i) => i.done).length;
        return (
          <div className="space-y-2">
            <div className="flex items-center gap-2 text-sm text-muted-foreground">
              <div className="flex-1 h-1.5 bg-muted rounded-full overflow-hidden">
                <div className="h-full bg-primary transition-all" style={{ width: `${(doneCount / items.length) * 100}%` }} />
              </div>
              <span className="tabular-nums">{doneCount}/{items.length}</span>
            </div>
            <div className="space-y-1">
              {items.map((item) => (
                <div key={item.id} className="flex items-center gap-2">
                  <Switch checked={item.done} disabled />
                  <span className={`text-sm ${item.done ? "line-through text-muted-foreground" : ""}`}>{item.text}</span>
                </div>
              ))}
            </div>
          </div>
        );
      }
      default:
        if (!value) return <span className="text-sm text-muted-foreground h-9 flex items-center">—</span>;
        return <span className="text-sm h-9 flex items-center">{value}</span>;
    }
  };

  if (readOnly) {
    if (hideLabel) return renderDisplay();
    return (
      <div className="space-y-1.5">
        <label className="text-sm font-medium text-muted-foreground">{field.name}</label>
        {renderDisplay()}
      </div>
    );
  }

  const renderEditor = () => {
    switch (field.fieldtype) {
      case "enumerated":
        return (
          <Select value={value} onValueChange={onChange} disabled={disabled}>
            <SelectTrigger className="h-9 w-full">
              <SelectValue placeholder="Select..." />
            </SelectTrigger>
            <SelectContent>
              {options.map((opt) => (
                <SelectItem key={opt.id} value={opt.id}>
                  <div className="flex items-center gap-2">
                    {opt.colour && (
                      <div
                        className="w-3 h-3 rounded-full"
                        style={{ backgroundColor: opt.colour }}
                      />
                    )}
                    {opt.name}
                  </div>
                </SelectItem>
              ))}
            </SelectContent>
          </Select>
        );

      case "text":
        // If rows is 1, render single-line input; otherwise render textarea
        if (field.rows === 1) {
          return (
            <Input
              value={localValue}
              onChange={(e) => handleTextChange(e.target.value)}
              onFocus={handleFocus}
              onBlur={handleBlur}
              disabled={disabled}
              autoFocus={autoFocus}
              className="h-9"
            />
          );
        }
        return (
          <Textarea
            value={localValue}
            onChange={(e) => handleTextChange(e.target.value)}
            onFocus={handleFocus}
            onBlur={handleBlur}
            disabled={disabled}
            autoFocus={autoFocus}
            rows={field.rows}
          />
        );

      case "number":
        return (
          <Input
            type="number"
            value={localValue}
            onChange={(e) => setLocalValue(e.target.value)}
            onFocus={handleFocus}
            onBlur={handleBlur}
            disabled={disabled}
            className="h-9"
          />
        );

      case "date":
        return (
          <DateEditor
            value={value}
            onChange={onChange}
            disabled={disabled}
            onErrorChange={(hasError) => onValidationError?.(hasError)}
          />
        );

      case "user":
        return (
          <PersonPicker
            mode="single"
            value={value}
            onChange={(v) => onChange(v as string)}
            local={localPeople}
            friends
            directory
            disabled={disabled}
            placeholder="Select..."
            emptyMessage="No people found"
          />
        );

      case "checkbox":
        return (
          <div className="pt-2">
            <Switch
              checked={value === "1" || value === "true"}
              onCheckedChange={(checked) => onChange(checked ? "1" : "0")}
              disabled={disabled}
            />
          </div>
        );

      case "checklist":
        return (
          <ChecklistEditor
            value={value}
            onChange={onChange}
            disabled={disabled}
          />
        );

      default:
        return (
          <Input
            value={localValue}
            onChange={(e) => setLocalValue(e.target.value)}
            onFocus={handleFocus}
            onBlur={handleBlur}
            disabled={disabled}
            className="h-9"
          />
        );
    }
  };

  if (hideLabel) return renderEditor();

  return (
    <div className="space-y-1.5">
      <label className="text-sm font-medium text-muted-foreground">
        {field.name}
      </label>
      {renderEditor()}
    </div>
  );
}

// Date editor component with blur validation
interface DateEditorProps {
  value: string;
  onChange: (value: string) => void;
  disabled?: boolean;
  onErrorChange: (error: boolean) => void;
}

function DateEditor({ value, onChange, disabled, onErrorChange }: DateEditorProps) {
  const inputRef = useRef<HTMLInputElement>(null);
  const [showError, setShowError] = useState(false);

  const handleBlur = (e: React.FocusEvent<HTMLInputElement>) => {
    if (e.target.validity.badInput) {
      setShowError(true);
      onErrorChange(true);
    } else {
      setShowError(false);
      onErrorChange(false);
      if (e.target.value !== value) {
        onChange(e.target.value);
      }
    }
  };

  const handleChange = (e: React.ChangeEvent<HTMLInputElement>) => {
    const badInput = e.target.validity.badInput;
    // Track bad input so parent can prevent close
    onErrorChange(badInput);
    // Clear visible error when user starts editing again
    if (showError) setShowError(false);
    // Save immediately when value changes and is valid (native date picker
    // fires onChange but may not trigger blur)
    if (!badInput && e.target.value !== value) {
      onChange(e.target.value);
    }
  };

  return (
    <div className="space-y-1">
      <Input
        ref={inputRef}
        type="date"
        defaultValue={value}
        onBlur={handleBlur}
        onChange={handleChange}
        disabled={disabled}
        className={`h-9 ${showError ? "border-destructive" : ""}`}
      />
      {showError && (
        <p className="text-xs text-destructive">Invalid date</p>
      )}
    </div>
  );
}

// Checklist editor component
interface ChecklistEditorProps {
  value: string;
  onChange: (value: string) => void;
  disabled?: boolean;
}

function ChecklistEditor({ value, onChange, disabled }: ChecklistEditorProps) {
  const [newItemText, setNewItemText] = useState("");
  const inputRef = useRef<HTMLInputElement>(null);

  // Parse checklist items from JSON string
  const items: ChecklistItem[] = (() => {
    if (!value) return [];
    try {
      return JSON.parse(value);
    } catch {
      return [];
    }
  })();

  const doneCount = items.filter((item) => item.done).length;
  const totalCount = items.length;

  // Generate a simple unique ID
  const generateId = () => {
    return Math.random().toString(36).substring(2, 8);
  };

  // Update items and notify parent
  const updateItems = (newItems: ChecklistItem[]) => {
    onChange(JSON.stringify(newItems));
  };

  // Toggle item done status
  const toggleItem = (id: string) => {
    const newItems = items.map((item) =>
      item.id === id ? { ...item, done: !item.done } : item
    );
    updateItems(newItems);
  };

  // Add new item
  const addItem = () => {
    if (!newItemText.trim()) return;
    const newItems = [
      ...items,
      { id: generateId(), text: newItemText.trim(), done: false },
    ];
    updateItems(newItems);
    setNewItemText("");
    inputRef.current?.focus();
  };

  // Remove item
  const removeItem = (id: string) => {
    const newItems = items.filter((item) => item.id !== id);
    updateItems(newItems);
  };

  // Update item text
  const updateItemText = (id: string, text: string) => {
    const newItems = items.map((item) =>
      item.id === id ? { ...item, text } : item
    );
    updateItems(newItems);
  };

  // Handle key press in new item input
  const handleKeyDown = (e: React.KeyboardEvent) => {
    if (e.key === "Enter") {
      e.preventDefault();
      addItem();
    }
  };

  return (
    <div className="space-y-2">
      {/* Progress indicator */}
      {totalCount > 0 && (
        <div className="flex items-center gap-2 text-sm text-muted-foreground">
          <div className="flex-1 h-1.5 bg-muted rounded-full overflow-hidden">
            <div
              className="h-full bg-primary transition-all"
              style={{ width: `${(doneCount / totalCount) * 100}%` }}
            />
          </div>
          <span className="tabular-nums">
            {doneCount}/{totalCount}
          </span>
        </div>
      )}

      {/* Existing items */}
      <div className="space-y-1">
        {items.map((item) => (
          <div
            key={item.id}
            className="flex items-center gap-2 group"
          >
            <Switch
              checked={item.done}
              onCheckedChange={() => toggleItem(item.id)}
              disabled={disabled}
            />
            <input
              type="text"
              value={item.text}
              onChange={(e) => updateItemText(item.id, e.target.value)}
              disabled={disabled}
              className={`flex-1 bg-transparent text-sm border-none outline-none ${
                item.done ? "line-through text-muted-foreground" : ""
              }`}
            />
            {!disabled && (
              <button
                type="button"
                onClick={() => removeItem(item.id)}
                className="opacity-0 group-hover:opacity-100 p-1 text-muted-foreground hover:text-destructive transition-opacity"
              >
                <Trash2 className="h-3.5 w-3.5" />
              </button>
            )}
          </div>
        ))}
      </div>

      {/* Add new item */}
      {!disabled && (
        <div className="flex items-center gap-2">
          <button
            type="button"
            onClick={() => {
              if (newItemText.trim()) {
                addItem();
              } else {
                inputRef.current?.focus();
              }
            }}
            className="p-1 -m-1 text-muted-foreground hover:text-foreground cursor-pointer"
          >
            <Plus className="h-4 w-4" />
          </button>
          <input
            ref={inputRef}
            type="text"
            value={newItemText}
            onChange={(e) => setNewItemText(e.target.value)}
            onKeyDown={handleKeyDown}
            placeholder="Add item..."
            className="flex-1 bg-transparent text-sm border-none outline-none placeholder:text-muted-foreground"
          />
          {newItemText && (
            <Button
              type="button"
              variant="ghost"
              size="sm"
              onClick={addItem}
              className="h-6 px-2 text-xs"
            >
              Add
            </Button>
          )}
        </div>
      )}
    </div>
  );
}
