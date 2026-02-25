// Mochi CRMs: Collapsible view options bar
// Copyright Alistair Cunningham 2026

import { useEffect, useRef } from "react";
import {
  Button,
  Input,
  Select,
  SelectContent,
  SelectGroup,
  SelectItem,
  SelectSeparator,
  SelectTrigger,
  SelectValue,
  SortDirectionButton,
  cn,
} from "@mochi/common";
import { Eye, LayoutGrid, ListTree } from "lucide-react";
import type { CrmDetails, CrmField, CrmView, SortState } from "@/types";
import type { FilterState } from "@/features/views/components/filter-bar";

const BUILT_IN_SORT_OPTIONS = [
  { id: "rank", label: "Manual" },
  { id: "number", label: "Number" },
  { id: "created", label: "Created" },
  { id: "updated", label: "Updated" },
] as const;

interface ViewOptionsBarProps {
  crm: CrmDetails;
  fields?: CrmField[];
  filters: FilterState;
  onFilterChange: (filters: FilterState) => void;
  activeViewId: string;
  onViewChange: (viewId: string) => void;
  sort: SortState | null;
  onSortChange: (sort: SortState) => void;
  showSort: boolean;
}

export function ViewOptionsBar({
  crm,
  fields,
  filters,
  onFilterChange,
  activeViewId,
  onViewChange,
  sort,
  onSortChange,
  showSort,
}: ViewOptionsBarProps) {
  const searchRef = useRef<HTMLInputElement>(null);

  // Build sort options: built-in + fields with 'sort' flag
  const sortFieldOptions = (fields || [])
    .filter((f) => f.flags?.split(",").includes("sort"))
    .map((f) => ({ id: `field:${f.id}`, label: f.name }));

  // Focus search input when bar mounts
  useEffect(() => {
    setTimeout(() => searchRef.current?.focus(), 0);
  }, []);

  return (
    <div className="flex items-center gap-2 px-4 py-2 bg-muted/30 flex-wrap">
      {/* View Switcher */}
      <div className="flex gap-1">
        {crm.views.map((view: CrmView) => (
          <button
            key={view.id}
            onClick={() => onViewChange(view.id)}
            className={cn(
              "flex items-center gap-1.5 px-2 py-1 rounded-md text-sm transition-colors",
              activeViewId === view.id
                ? "bg-primary text-primary-foreground"
                : "hover:bg-muted"
            )}
          >
            {view.viewtype === "list" ? (
              <ListTree className="size-3.5" />
            ) : (
              <LayoutGrid className="size-3.5" />
            )}
            {view.name}
          </button>
        ))}
      </div>

      <div className="w-px h-5 bg-border" />

      {/* Search */}
      <Input
        ref={searchRef}
        type="search"
        placeholder="Search..."
        value={filters.search}
        onChange={(e) => onFilterChange({ ...filters, search: e.target.value })}
        className="h-7 text-xs w-[200px]"
      />

      {/* Watched filter */}
      <Button
        variant={filters.watched ? "secondary" : "ghost"}
        size="sm"
        className="h-7 px-2 text-xs"
        onClick={() => onFilterChange({ ...filters, watched: !filters.watched })}
      >
        <Eye className="size-3.5 mr-1" />
        Watched
      </Button>

      {/* Sort (only for list view) */}
      {showSort && (
        <div className="flex items-center gap-2 ml-auto">
          <Select
            value={sort?.field || "rank"}
            onValueChange={(value) =>
              onSortChange({ field: value, direction: sort?.direction || "asc" })
            }
          >
            <SelectTrigger className="h-7 text-xs w-auto">
              <SelectValue />
            </SelectTrigger>
            <SelectContent>
              {sortFieldOptions.length > 0 && (
                <>
                <SelectGroup>
                  {sortFieldOptions.map((option) => (
                    <SelectItem key={option.id} value={option.id}>
                      {option.label}
                    </SelectItem>
                  ))}
                </SelectGroup>
                <SelectSeparator />
                </>
              )}
              <SelectGroup>
                {BUILT_IN_SORT_OPTIONS.map((option) => (
                  <SelectItem key={option.id} value={option.id}>
                    {option.label}
                  </SelectItem>
                ))}
              </SelectGroup>
            </SelectContent>
          </Select>
          <SortDirectionButton
            direction={sort?.direction || "asc"}
            onToggle={() =>
              onSortChange({
                field: sort?.field || "rank",
                direction: sort?.direction === "asc" ? "desc" : "asc",
              })
            }
            size="sm"
          />
        </div>
      )}
    </div>
  );
}
