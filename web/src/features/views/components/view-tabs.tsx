// Mochi CRMs: View tabs component
// Copyright Alistair Cunningham 2026

import { cn } from "@mochi/common";
import { LayoutGrid, ListTree, Plus } from "lucide-react";
import type { CrmView } from "@/types";

interface ViewTabsProps {
  views: CrmView[];
  activeViewId: string;
  onViewChange: (viewId: string) => void;
  onAddView?: () => void;
}

export function ViewTabs({
  views,
  activeViewId,
  onViewChange,
  onAddView,
}: ViewTabsProps) {
  const getViewIcon = (viewtype: string) => {
    switch (viewtype) {
      case "list":
        return <ListTree className="size-4" />;
      case "board":
      default:
        return <LayoutGrid className="size-4" />;
    }
  };

  return (
    <div className="flex items-center gap-1 border-b border-border">
      {views.map((view) => (
        <button
          key={view.id}
          onClick={() => onViewChange(view.id)}
          className={cn(
            "flex items-center gap-2 px-3 py-2 text-sm font-medium border-b-2 -mb-px transition-colors",
            activeViewId === view.id
              ? "border-primary text-foreground"
              : "border-transparent text-muted-foreground hover:text-foreground hover:border-muted-foreground/50",
          )}
        >
          {getViewIcon(view.viewtype)}
          {view.name}
        </button>
      ))}
      {onAddView && (
        <button
          onClick={onAddView}
          className="flex items-center gap-1 px-2 py-2 text-sm text-muted-foreground hover:text-foreground transition-colors"
          title="Add view"
        >
          <Plus className="size-4" />
        </button>
      )}
    </div>
  );
}
