// Mochi CRMs: Object link display and management
// Copyright Alistair Cunningham 2026

import { useState, useMemo } from "react";
import { useMutation, useQueryClient, useQuery } from "@tanstack/react-query";
import { Link2, Plus, X } from "lucide-react";
import {
  Badge,
  Button,
  Input,
  Popover,
  PopoverContent,
  PopoverTrigger,
  Select,
  SelectContent,
  SelectItem,
  SelectTrigger,
  SelectValue,
  getErrorMessage,
  toast,
} from "@mochi/common";
import crmsApi from "@/api/crms";
import type { CrmObject, CrmClass, ObjectLink } from "@/types";

interface ObjectLinksProps {
  crmId: string;
  objectId: string;
  outgoing: ObjectLink[];
  incoming: ObjectLink[];
  classes: CrmClass[];
  readOnly: boolean;
}

const LINK_TYPE_LABELS: Record<string, string> = {
  relates: "Relates",
  blocks: "Blocks",
  duplicates: "Duplicates",
  "blocked by": "Blocked by",
};

export function ObjectLinks({
  crmId,
  objectId,
  outgoing,
  incoming,
  classes,
  readOnly,
}: ObjectLinksProps) {
  const [popoverOpen, setPopoverOpen] = useState(false);
  const [linkType, setLinkType] = useState("relates");
  const [search, setSearch] = useState("");
  const queryClient = useQueryClient();

  const objectTitle = (obj: { class: string; values: Record<string, string> }) => {
    const cls = classes.find((c) => c.id === obj.class);
    return (cls?.title ? obj.values[cls.title] : "") || "Untitled";
  };

  const { data: objectListData } = useQuery({
    queryKey: ["objects", crmId],
    queryFn: async () => {
      const response = await crmsApi.listObjects(crmId);
      return response.data;
    },
  });

  const createLinkMutation = useMutation({
    mutationFn: async ({
      source,
      target,
      linktype,
    }: {
      source: string;
      target: string;
      linktype: string;
    }) => {
      return crmsApi.createLink(crmId, source, target, linktype);
    },
    onSuccess: () => {
      queryClient.invalidateQueries({
        queryKey: ["object", crmId, objectId],
      });
      setPopoverOpen(false);
      setSearch("");
      setLinkType("relates");
    },
    onError: (error) => {
      toast.error(getErrorMessage(error, "Failed to create link"));
    },
  });

  const deleteLinkMutation = useMutation({
    mutationFn: async ({
      source,
      target,
      linktype,
    }: {
      source: string;
      target: string;
      linktype: string;
    }) => {
      return crmsApi.deleteLink(crmId, source, target, linktype);
    },
    onSuccess: () => {
      queryClient.invalidateQueries({
        queryKey: ["object", crmId, objectId],
      });
    },
    onError: (error) => {
      toast.error(getErrorMessage(error, "Failed to delete link"));
    },
  });

  // Build display list combining outgoing and incoming
  const objectsMap = useMemo(() => {
    const map = new Map<string, CrmObject>();
    for (const obj of objectListData?.objects || []) {
      map.set(obj.id, obj);
    }
    return map;
  }, [objectListData]);

  const displayLinks = useMemo(() => {
    const items: {
      id: string;
      label: string;
      displayName: string;
      source: string;
      target: string;
      linktype: string;
    }[] = [];

    for (const link of outgoing) {
      const linkedObj = objectsMap.get(link.target!);
      items.push({
        id: `out-${link.target}-${link.linktype}`,
        label: LINK_TYPE_LABELS[link.linktype] || link.linktype,
        displayName: linkedObj ? objectTitle(linkedObj) : (link.title || "Untitled"),
        source: objectId,
        target: link.target!,
        linktype: link.linktype,
      });
    }

    for (const link of incoming) {
      const linkedObj = objectsMap.get(link.source!);
      items.push({
        id: `in-${link.source}-${link.linktype}`,
        label: link.linktype === "blocks" ? "Blocked by" : (LINK_TYPE_LABELS[link.linktype] || link.linktype),
        displayName: linkedObj ? objectTitle(linkedObj) : (link.title || "Untitled"),
        source: link.source!,
        target: objectId,
        linktype: link.linktype,
      });
    }

    return items;
  }, [outgoing, incoming, objectId, objectsMap]);

  // Filter objects for the add-link search
  const linkedObjectIds = useMemo(() => {
    const ids = new Set<string>();
    ids.add(objectId);
    for (const link of outgoing) {
      if (link.target) ids.add(link.target);
    }
    for (const link of incoming) {
      if (link.source) ids.add(link.source);
    }
    return ids;
  }, [outgoing, incoming, objectId]);

  const searchResults = useMemo(() => {
    if (!objectListData?.objects || !search.trim()) return [];
    const q = search.toLowerCase();
    return objectListData.objects
      .filter((obj: CrmObject) => {
        if (linkedObjectIds.has(obj.id)) return false;
        const title = objectTitle(obj).toLowerCase();
        return title.includes(q);
      })
      .slice(0, 10);
  }, [objectListData, search, linkedObjectIds]);

  const handleAddLink = (targetObj: CrmObject) => {
    if (linkType === "blocked by") {
      // Swap: create blocks from target → current object
      createLinkMutation.mutate({
        source: targetObj.id,
        target: objectId,
        linktype: "blocks",
      });
    } else {
      createLinkMutation.mutate({
        source: objectId,
        target: targetObj.id,
        linktype: linkType,
      });
    }
  };

  if (displayLinks.length === 0 && readOnly) {
    return null;
  }

  return (
    <div className="grid grid-cols-[120px_1fr] gap-4 items-start">
      <label className="text-sm font-medium text-muted-foreground pt-2 flex items-center gap-1.5">
        <Link2 className="size-3.5" />
        Links
      </label>
      <div className="space-y-1.5 pt-1">
        {displayLinks.map((link) => (
          <div
            key={link.id}
            className="group flex items-center gap-1.5 text-xs"
          >
            <Badge
              variant="secondary"
              className="text-[10px] px-1.5 py-0 h-4 font-normal"
            >
              {link.label}
            </Badge>
            <span className="truncate">{link.displayName}</span>
            {!readOnly && (
              <button
                type="button"
                className="hidden group-hover:inline-flex ml-auto text-muted-foreground hover:text-destructive shrink-0"
                onClick={() =>
                  deleteLinkMutation.mutate({
                    source: link.source,
                    target: link.target,
                    linktype: link.linktype,
                  })
                }
              >
                <X className="size-3" />
              </button>
            )}
          </div>
        ))}

        {!readOnly && (
          <Popover open={popoverOpen} onOpenChange={setPopoverOpen}>
            <PopoverTrigger asChild>
              <Button variant="outline" size="sm" className="h-7 text-xs">
                <Plus className="size-3 mr-1.5" />
                Add link
              </Button>
            </PopoverTrigger>
            <PopoverContent align="start" className="w-72 p-3 space-y-3">
              <Select value={linkType} onValueChange={setLinkType}>
                <SelectTrigger className="w-full h-8 text-xs">
                  <SelectValue />
                </SelectTrigger>
                <SelectContent>
                  {Object.entries(LINK_TYPE_LABELS).map(([value, label]) => (
                    <SelectItem key={value} value={value} className="text-xs">
                      {label}
                    </SelectItem>
                  ))}
                </SelectContent>
              </Select>
              <Input
                placeholder="Search objects..."
                value={search}
                onChange={(e) => setSearch(e.target.value)}
                className="h-8 text-xs"
                autoFocus
              />
              {searchResults.length > 0 && (
                <div className="max-h-48 overflow-y-auto space-y-0.5">
                  {searchResults.map((obj: CrmObject) => (
                    <button
                      key={obj.id}
                      type="button"
                      className="w-full text-left px-2 py-1.5 text-xs rounded hover:bg-accent flex items-center gap-1.5"
                      onClick={() => handleAddLink(obj)}
                      disabled={createLinkMutation.isPending}
                    >
                      <span className="truncate">
                        {objectTitle(obj)}
                      </span>
                    </button>
                  ))}
                </div>
              )}
              {search.trim() && searchResults.length === 0 && (
                <p className="text-xs text-muted-foreground text-center py-2">
                  No matching objects
                </p>
              )}
            </PopoverContent>
          </Popover>
        )}
      </div>
    </div>
  );
}
