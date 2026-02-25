// Mochi CRMs: Object detail dialog component
// Copyright Alistair Cunningham 2026

import { useState, useMemo } from "react";
import { useQuery, useMutation, useQueryClient } from "@tanstack/react-query";
import { Eye, EyeOff, Trash2, MessageSquare, Activity, Settings2, X } from "lucide-react";
import {
  Button,
  Input,
  ConfirmDialog,
  DataChip,
  Sheet,
  SheetContent,
  Select,
  SelectContent,
  SelectItem,
  SelectTrigger,
  SelectValue,
  cn,
  GeneralError,
  ListSkeleton,
} from "@mochi/common";
import crmsApi from "@/api/crms";
import type { CrmAccess, CrmDetails } from "@/types";
import { canWrite, canComment } from "@/lib/access";
import { FieldEditor } from "./field-editor";
import { CommentList } from "./comment-list";
import { ActivityList } from "./activity-list";
import { ObjectAttachments } from "./object-attachments";

interface ObjectDetailPanelProps {
  crmId: string;
  objectId: string | null;
  crm: CrmDetails;
  access: CrmAccess;
  onClose: () => void;
}

type Tab = "properties" | "comments" | "activity";

export function ObjectDetailPanel({
  crmId,
  objectId,
  crm,
  access,
  onClose,
}: ObjectDetailPanelProps) {
  const [activeTab, setActiveTab] = useState<Tab>("properties");
  const [editingTitle, setEditingTitle] = useState(false);
  const [titleValue, setTitleValue] = useState("");
  const [showDeleteDialog, setShowDeleteDialog] = useState(false);
  const [validationErrors, setValidationErrors] = useState<Set<string>>(new Set());
  const queryClient = useQueryClient();

  // Track validation errors from fields
  const handleValidationError = (fieldId: string, hasError: boolean) => {
    setValidationErrors((prev) => {
      const next = new Set(prev);
      if (hasError) {
        next.add(fieldId);
      } else {
        next.delete(fieldId);
      }
      return next;
    });
  };

  // Try to close, but prevent if there are validation errors
  const handleClose = () => {
    if (validationErrors.size > 0) {
      // Don't close - there are validation errors
      return;
    }
    onClose();
  };

  const { data, isLoading, error } = useQuery({
    queryKey: ["object", crmId, objectId],
    queryFn: async () => {
      if (!objectId) throw new Error("No object ID");
      const response = await crmsApi.getObject(crmId, objectId);
      return response.data;
    },
    enabled: !!objectId,
    // Use cached objects list as placeholder so the panel renders immediately
    placeholderData: () => {
      const cached = queryClient.getQueryData<{ objects: Array<{ id: string; crm: string; class: string; number: number; parent: string; rank: number; created: number; updated: number; values: Record<string, string> }>; watched?: string[] }>(["objects", crmId]);
      if (!cached || !objectId) return undefined;
      const obj = cached.objects.find((o) => o.id === objectId);
      if (!obj) return undefined;
      return {
        object: { ...obj, readable: `${crm.crm.prefix}-${obj.number}` },
        values: obj.values,
        links: [],
        linked_by: [],
        watching: cached.watched?.includes(objectId) ?? false,
        comment_count: 0,
      };
    },
  });

  // Fetch crm members for the owner picker
  const { data: peopleData } = useQuery({
    queryKey: ["people", crmId],
    queryFn: async () => {
      const response = await crmsApi.listPeople(crmId);
      return response.data.people;
    },
    staleTime: 60000, // Cache for 1 minute
  });

  // Fetch all objects for parent picker (shares cache with crm page)
  const { data: objectListData } = useQuery({
    queryKey: ["objects", crmId],
    queryFn: async () => {
      const response = await crmsApi.listObjects(crmId);
      return response.data;
    },
  });
  const objectsData = objectListData?.objects;

  const updateValueMutation = useMutation({
    mutationFn: async ({ field, value }: { field: string; value: string }) => {
      if (!objectId) return;
      await crmsApi.setValue(crmId, objectId, field, value);
    },
    onSuccess: () => {
      queryClient.invalidateQueries({
        queryKey: ["object", crmId, objectId],
      });
      queryClient.invalidateQueries({
        queryKey: ["objects", crmId],
      });
    },
  });

  const watchMutation = useMutation({
    mutationFn: async (watching: boolean) => {
      if (!objectId) return;
      if (watching) {
        return crmsApi.removeWatcher(crmId, objectId);
      } else {
        return crmsApi.addWatcher(crmId, objectId);
      }
    },
    onSuccess: () => {
      queryClient.invalidateQueries({
        queryKey: ["object", crmId, objectId],
      });
    },
  });

  const deleteMutation = useMutation({
    mutationFn: async () => {
      if (!objectId) return;
      return crmsApi.deleteObject(crmId, objectId);
    },
    onSuccess: () => {
      setShowDeleteDialog(false);
      queryClient.invalidateQueries({
        queryKey: ["objects", crmId],
      });
      onClose();
    },
  });

  const updateParentMutation = useMutation({
    mutationFn: async (newParent: string) => {
      if (!objectId) return;
      return crmsApi.updateObject(crmId, objectId, { parent: newParent });
    },
    onSuccess: () => {
      queryClient.invalidateQueries({
        queryKey: ["object", crmId, objectId],
      });
      queryClient.invalidateQueries({
        queryKey: ["objects", crmId],
      });
    },
  });

  // Get valid parent options based on hierarchy rules - must be before early returns
  const validParentOptions = useMemo(() => {
    if (!objectsData || !data) return [];

    const object = data.object;
    // Get allowed parent types for this object type
    const allowedParentClasses = crm.hierarchy[object.class] || [];
    const parentClassIds = allowedParentClasses.filter((t) => t !== "");

    if (parentClassIds.length === 0) return [];

    // Filter objects to those matching allowed parent types
    // Also exclude this object and its descendants
    const descendants = new Set<string>();
    const findDescendants = (id: string) => {
      descendants.add(id);
      for (const obj of objectsData) {
        if (obj.parent === id && !descendants.has(obj.id)) {
          findDescendants(obj.id);
        }
      }
    };
    findDescendants(object.id);

    return objectsData.filter(
      (obj) => parentClassIds.includes(obj.class) && !descendants.has(obj.id)
    );
  }, [objectsData, data, crm.hierarchy]);

  // Get current parent object info - must be before early returns
  const currentParent = useMemo(() => {
    if (!data?.object.parent || !objectsData) return null;
    return objectsData.find((obj) => obj.id === data.object.parent);
  }, [data, objectsData]);

  if (!objectId) {
    return null;
  }

  if (isLoading) {
    return (
      <Sheet open={true} onOpenChange={handleClose} modal={false}>
        <SheetContent className="w-full sm:max-w-2xl p-0 gap-0">
          <div className="p-6">
            <ListSkeleton variant="simple" height="h-12" count={3} />
          </div>
        </SheetContent>
      </Sheet>
    );
  }

  if (error || !data) {
    return (
      <Sheet open={true} onOpenChange={handleClose} modal={false}>
        <SheetContent className="w-full sm:max-w-2xl p-6">
          <GeneralError error={error ?? new Error("Failed to load object")} minimal mode="inline" />
        </SheetContent>
      </Sheet>
    );
  }

  const object = data.object;
  const classFields = crm.fields[object.class] || [];
  const classOptions = crm.options[object.class] || {};
  const cls = crm.classes.find((c) => c.id === object.class);
  const titleField = cls?.title ? classFields.find((f) => f.id === cls.title) : undefined;
  const title = (titleField ? data.values[titleField.id] : "") || object.readable;
  // Get display title for any object using its class's title field
  const objectTitle = (obj: { class: string; number: number; values: Record<string, string> }) => {
    const objCls = crm.classes.find((c) => c.id === obj.class);
    return (objCls?.title ? obj.values[objCls.title] : "") || `${crm.crm.prefix}-${obj.number}`;
  };

  const tabs: { id: Tab; label: string; icon: React.ReactNode }[] = [
    { id: "properties", label: "Properties", icon: <Settings2 className="size-4" /> },
    { id: "comments", label: `Comments (${data.comment_count || 0})`, icon: <MessageSquare className="size-4" /> },
    { id: "activity", label: "Activity", icon: <Activity className="size-4" /> },
  ];

  const handleTitleSave = () => {
    const currentTitle = titleField ? data.values[titleField.id] : "";
    if (titleField && titleValue !== currentTitle) {
      updateValueMutation.mutate({ field: titleField.id, value: titleValue });
    }
    setEditingTitle(false);
  };

  const handleFieldChange = (fieldId: string, value: string) => {
    updateValueMutation.mutate({ field: fieldId, value });
  };

  return (
    <Sheet open={true} onOpenChange={handleClose} modal={false}>
      <SheetContent className="w-full sm:max-w-3xl p-0 gap-0 [&>button:last-child]:hidden">
        {/* Header */}
        <div className="flex items-center gap-3 px-6 py-4 border-b shrink-0">
          {editingTitle && canWrite(access) ? (
            <Input
              value={titleValue}
              onChange={(e) => setTitleValue(e.target.value)}
              onBlur={handleTitleSave}
              onKeyDown={(e) => {
                if (e.key === "Enter") {
                  e.preventDefault();
                  handleTitleSave();
                }
                if (e.key === "Escape") {
                  setEditingTitle(false);
                }
              }}
              className="text-xl font-bold flex-1"
              autoFocus
            />
          ) : (
            <h2
              className={cn(
                "text-xl font-bold leading-tight truncate flex-1 min-w-0",
                canWrite(access) && "cursor-pointer hover:text-primary transition-colors"
              )}
              onClick={canWrite(access) && titleField ? () => {
                setTitleValue(titleField ? data.values[titleField.id] || "" : "");
                setEditingTitle(true);
              } : undefined}
            >
              {title}
            </h2>
          )}
          <div className="flex items-center gap-1 shrink-0">
            <Button
              variant="ghost"
              size="icon"
              className="h-8 w-8"
              onClick={() => watchMutation.mutate(data.watching)}
              disabled={watchMutation.isPending}
              title={data.watching ? "Stop watching" : "Watch"}
            >
              {data.watching ? (
                <Eye className="size-4" />
              ) : (
                <EyeOff className="size-4" />
              )}
            </Button>
            {canWrite(access) && (
              <Button
                variant="ghost"
                size="icon"
                className="h-8 w-8 text-muted-foreground hover:text-destructive hover:bg-destructive/10"
                onClick={() => setShowDeleteDialog(true)}
                title="Delete item"
              >
                <Trash2 className="size-4" />
              </Button>
            )}
            <Button
              variant="ghost"
              size="icon"
              className="h-8 w-8"
              onClick={handleClose}
              title="Close"
            >
              <X className="size-4" />
            </Button>
          </div>
        </div>

        {/* Tabs */}
        <div className="flex gap-1 border-b px-6 shrink-0">
          {tabs.map((tab) => (
            <button
              key={tab.id}
              onClick={() => setActiveTab(tab.id)}
              className={cn(
                "flex items-center gap-2 px-4 py-2 text-sm font-medium transition-colors",
                "border-b-2 -mb-px",
                activeTab === tab.id
                  ? "border-primary text-foreground"
                  : "border-transparent text-muted-foreground hover:text-foreground"
              )}
            >
              {tab.icon}
              {tab.label}
            </button>
          ))}
        </div>

        {/* Tab content */}
        <div className="flex-1 overflow-y-auto p-6">
          {activeTab === "properties" && (
            <div className="max-w-2xl space-y-6">
              {/* ID */}
              <div className="grid grid-cols-[120px_1fr] gap-4 items-start">
                <label className="text-sm font-medium text-muted-foreground pt-2">
                  ID
                </label>
                <DataChip value={object.readable} copyable chipClassName="bg-primary/10 border-primary/20 text-primary font-bold text-[11px]" />
              </div>

              {/* Parent */}
              {(validParentOptions.length > 0 || currentParent) && (
                <div className="grid grid-cols-[120px_1fr] gap-4 items-start">
                  <label className="text-sm font-medium text-muted-foreground pt-2">
                    Parent
                  </label>
                  {!canWrite(access) ? (
                    <span className="text-sm h-9 flex items-center">
                      {currentParent
                        ? objectTitle(currentParent)
                        : "None"}
                    </span>
                  ) : (
                    <Select
                      value={object.parent || "_none_"}
                      onValueChange={(value) => updateParentMutation.mutate(value === "_none_" ? "" : value)}
                      disabled={updateParentMutation.isPending}
                    >
                      <SelectTrigger className="w-full">
                        <SelectValue placeholder="None">
                          {currentParent
                            ? objectTitle(currentParent)
                            : "None"}
                        </SelectValue>
                      </SelectTrigger>
                      <SelectContent>
                        <SelectItem value="_none_">None</SelectItem>
                        {validParentOptions.map((obj) => (
                          <SelectItem key={obj.id} value={obj.id}>
                            {objectTitle(obj)}
                          </SelectItem>
                        ))}
                      </SelectContent>
                    </Select>
                  )}
                </div>
              )}

              {classFields
                .filter((f) => f.id !== cls?.title)
                .map((field) => (
                  <div key={field.id} className="grid grid-cols-[120px_1fr] gap-4 items-start">
                    <label className="text-sm font-medium text-muted-foreground pt-2">
                      {field.name}
                    </label>
                    <FieldEditor
                      field={field}
                      value={data.values[field.id] || ""}
                      options={classOptions[field.id] || []}
                      onChange={(value) => handleFieldChange(field.id, value)}
                      readOnly={!canWrite(access)}
                      hideLabel
                      localPeople={peopleData}
                      onValidationError={(hasError) => handleValidationError(field.id, hasError)}
                    />
                  </div>
                ))}

              <ObjectAttachments
                crmId={crmId}
                objectId={objectId!}
                readOnly={!canWrite(access)}
              />
            </div>
          )}

          {activeTab === "comments" && (
            <div className="max-w-2xl">
              <CommentList crmId={crmId} objectId={objectId} readOnly={!canComment(access)} />
            </div>
          )}

          {activeTab === "activity" && (
            <div className="max-w-2xl">
              <ActivityList crmId={crmId} objectId={objectId} />
            </div>
          )}
        </div>

        <ConfirmDialog
          open={showDeleteDialog}
          onOpenChange={setShowDeleteDialog}
          title="Delete item"
          desc={`Are you sure you want to delete "${title}"? This action cannot be undone.`}
          confirmText="Delete"
          destructive
          isLoading={deleteMutation.isPending}
          handleConfirm={() => deleteMutation.mutate()}
        />
      </SheetContent>
    </Sheet>
  );
}
