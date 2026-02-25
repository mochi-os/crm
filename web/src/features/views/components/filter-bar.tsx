// Mochi CRMs: Filter bar component
// Copyright Alistair Cunningham 2026

import { X } from "lucide-react";
import { Button } from "@mochi/common";

export interface FilterState {
  search: string;
  watched: boolean;
}

interface FilterBarProps {
  filters: FilterState;
  onFilterChange: (filters: FilterState) => void;
}

export function FilterBar({
  filters,
  onFilterChange,
}: FilterBarProps) {
  const clearFilter = (key: keyof FilterState) => {
    onFilterChange({ ...filters, [key]: key === "watched" ? false : "" });
  };

  const clearAllFilters = () => {
    onFilterChange({ search: "", watched: false });
  };

  const activeFilters: {
    key: keyof FilterState;
    label: string;
    value: string;
  }[] = [];

  if (filters.search) {
    activeFilters.push({
      key: "search",
      label: "Search",
      value: filters.search,
    });
  }
  if (filters.watched) {
    activeFilters.push({
      key: "watched",
      label: "Watched",
      value: "On",
    });
  }

  // Don't render anything if no active filters
  if (activeFilters.length === 0) {
    return null;
  }

  return (
    <div className="flex items-center gap-2 flex-wrap">
      {/* Active filter chips */}
      {activeFilters.map((filter) => (
        <span
          key={filter.key}
          className="inline-flex items-center gap-1 px-2 py-0.5 text-xs font-medium bg-muted rounded-full"
        >
          <span className="text-muted-foreground">{filter.label}:</span>
          <span className="truncate max-w-[100px]">{filter.value}</span>
          <button
            onClick={() => clearFilter(filter.key)}
            className="ml-0.5 hover:text-destructive"
          >
            <X className="size-3" />
          </button>
        </span>
      ))}

      {/* Clear all filters */}
      {activeFilters.length > 1 && (
        <Button
          variant="ghost"
          size="sm"
          className="h-6 text-xs text-muted-foreground"
          onClick={clearAllFilters}
        >
          Clear all
        </Button>
      )}
    </div>
  );
}
