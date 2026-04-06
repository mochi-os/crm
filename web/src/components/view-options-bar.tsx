// Mochi CRMs: Collapsible view options bar
// Copyright Alistair Cunningham 2026

import { useEffect, useRef, useState } from "react";
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
} from "@mochi/web";
import { Eye, LayoutGrid, ListTree, Search, X } from "lucide-react";
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
  const desktopSearchRef = useRef<HTMLInputElement>(null);
  const mobileSearchRef = useRef<HTMLInputElement>(null);
  const [isMobileSearchOpen, setIsMobileSearchOpen] = useState(false);
  const hasSearchValue = filters.search.trim().length > 0;
  const showMobileSearch = isMobileSearchOpen || hasSearchValue;

  // Build sort options: built-in + fields with 'sort' flag
  const sortFieldOptions = (fields || [])
    .filter((f) => f.flags?.split(",").includes("sort"))
    .map((f) => ({ id: `field:${f.id}`, label: f.name }));

  const updateSearch = (search: string) => {
    onFilterChange({ ...filters, search });
  };

  const closeMobileSearch = () => {
    updateSearch("");
    setIsMobileSearchOpen(false);
  };

  // Focus desktop search input when the bar mounts on larger screens
  useEffect(() => {
    const timer = setTimeout(() => {
      if (window.innerWidth >= 640) {
        desktopSearchRef.current?.focus();
      }
    }, 0);

    return () => clearTimeout(timer);
  }, []);

  // Focus the expanded mobile search field only after the user opens it
  useEffect(() => {
    if (!isMobileSearchOpen) {
      return;
    }

    const timer = setTimeout(() => mobileSearchRef.current?.focus(), 0);
    return () => clearTimeout(timer);
  }, [isMobileSearchOpen]);

  return (
    <div className="bg-muted/30">
      {/* View switcher — scrolls horizontally on mobile */}
      <div className="overflow-x-auto no-scrollbar">
        <div className="flex items-center gap-1 px-4 pt-2 pb-1 min-w-max">
          {crm.views.map((view: CrmView) => (
            <button
              key={view.id}
              onClick={() => onViewChange(view.id)}
              className={cn(
                "flex items-center gap-1.5 px-2 py-1 rounded-md text-sm transition-colors whitespace-nowrap",
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
      </div>

      {/* Controls row */}
      <div className="px-4 pb-2">
        {showMobileSearch && (
          <div className="flex items-center gap-2 pb-2 sm:hidden">
            <Input
              ref={mobileSearchRef}
              type="search"
              placeholder="Search..."
              value={filters.search}
              onChange={(e) => updateSearch(e.target.value)}
              className="h-7 min-w-0 flex-1 text-xs"
            />
            <Button
              variant="ghost"
              size="sm"
              className="h-7 w-7 px-0"
              aria-label="Close search"
              onClick={closeMobileSearch}
            >
              <X className="size-3.5" />
            </Button>
          </div>
        )}

        <div className="flex flex-wrap items-center gap-2">
          {/* Search */}
          <Input
            ref={desktopSearchRef}
            type="search"
            placeholder="Search..."
            value={filters.search}
            onChange={(e) => updateSearch(e.target.value)}
            className="hidden h-7 w-[200px] text-xs sm:block"
          />
          {!showMobileSearch && (
            <Button
              variant="ghost"
              size="sm"
              className="h-7 w-7 px-0 sm:hidden"
              aria-label="Open search"
              onClick={() => setIsMobileSearchOpen(true)}
            >
              <Search className="size-3.5" />
            </Button>
          )}

          {/* Watched filter */}
          <Button
            variant={filters.watched ? "secondary" : "ghost"}
            size="sm"
            className="h-7 px-2 text-xs"
            aria-label="Toggle watched filter"
            onClick={() => onFilterChange({ ...filters, watched: !filters.watched })}
          >
            <Eye className="size-3.5 sm:mr-1" />
            <span className="sr-only sm:not-sr-only">Watched</span>
          </Button>

          {/* Sort (only for list view) */}
          {showSort && (
            <div className="ml-auto flex items-center gap-2">
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
      </div>
    </div>
  );
}
