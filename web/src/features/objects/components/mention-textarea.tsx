// Mochi CRMs: Textarea with @mention autocomplete
// Copyright Alistair Cunningham 2026

import { useRef, useState } from "react";
import { cn } from "@mochi/web";

interface Person {
  id: string;
  name: string;
}

interface MentionTextareaProps
  extends Omit<React.TextareaHTMLAttributes<HTMLTextAreaElement>, "onChange"> {
  value: string;
  onValueChange: (value: string) => void;
  people?: Person[];
}

function getMentionQuery(text: string, cursorPos: number): string | null {
  const match = text.slice(0, cursorPos).match(/@(\w*)$/);
  return match ? match[1] : null;
}

export function MentionTextarea({
  value,
  onValueChange,
  people = [],
  className,
  onKeyDown,
  ...props
}: MentionTextareaProps) {
  const textareaRef = useRef<HTMLTextAreaElement>(null);
  const [mentionQuery, setMentionQuery] = useState<string | null>(null);

  const filtered =
    mentionQuery !== null
      ? people
          .filter((p) => p.name.toLowerCase().startsWith(mentionQuery.toLowerCase()))
          .slice(0, 8)
      : [];
  const isOpen = mentionQuery !== null && filtered.length > 0;

  const handleChange = (e: React.ChangeEvent<HTMLTextAreaElement>) => {
    onValueChange(e.target.value);
    const cursor = e.target.selectionStart ?? e.target.value.length;
    setMentionQuery(getMentionQuery(e.target.value, cursor));
  };

  const handleKeyDown = (e: React.KeyboardEvent<HTMLTextAreaElement>) => {
    if (e.key === "Escape" && mentionQuery !== null) {
      e.stopPropagation();
      setMentionQuery(null);
      return;
    }
    onKeyDown?.(e);
  };

  const insertMention = (person: Person) => {
    const textarea = textareaRef.current;
    if (!textarea) return;
    const cursor = textarea.selectionStart ?? value.length;
    const before = value.slice(0, cursor).replace(/@\w*$/, `@${person.name} `);
    onValueChange(before + value.slice(cursor));
    setMentionQuery(null);
    setTimeout(() => {
      textarea.focus();
      textarea.setSelectionRange(before.length, before.length);
    }, 0);
  };

  return (
    <div className="relative">
      <textarea
        ref={textareaRef}
        value={value}
        onChange={handleChange}
        onKeyDown={handleKeyDown}
        className={cn(
          "border-input bg-background min-h-16 w-full rounded-lg border px-3 py-2 text-sm",
          className,
        )}
        {...props}
      />
      {isOpen && (
        <div className="absolute z-50 mt-1 w-56 overflow-hidden rounded-md border bg-popover shadow-md">
          {filtered.map((person) => (
            <button
              key={person.id}
              type="button"
              className="flex w-full items-center px-3 py-2 text-left text-sm hover:bg-accent hover:text-accent-foreground"
              onMouseDown={(e) => {
                e.preventDefault();
                insertMention(person);
              }}
            >
              {person.name}
            </button>
          ))}
        </div>
      )}
    </div>
  );
}
