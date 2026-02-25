// Mochi CRMs: Design editor main component
// Copyright Alistair Cunningham 2026

import { useState, useMemo } from "react";
import { useMutation, useQueryClient } from "@tanstack/react-query";
import { Button, Label, toast, getErrorMessage } from "@mochi/common";
import { Blocks, GripVertical, Plus } from "lucide-react";
import crmsApi from "@/api/crms";
import type { CrmDetails, CrmField, CrmView, FieldOption } from "@/types";
import { DesignPreview } from "./design-preview";
import { AddFieldDialog } from "./add-dialogs";
import {
  ViewSheet,
  ClassSheet,
  EditFieldDialog,
} from "./edit-dialogs";
import { OptionDialog } from "./option-dialog";
import type { PendingField } from "./edit-dialogs";

interface DesignEditorProps {
  crmId: string;
  crm: CrmDetails;
}

export function DesignEditor({ crmId, crm }: DesignEditorProps) {
  const queryClient = useQueryClient();

  // Selection state
  const [selectedClassId, setSelectedClassId] = useState<string | null>(
    crm.classes[0]?.id || null,
  );

  // Add dialog state
  const [addClassOpen, setAddClassOpen] = useState(false);
  const [addFieldOpen, setAddFieldOpen] = useState(false);
  const [addOptionOpen, setAddOptionOpen] = useState(false);
  const [addViewOpen, setAddViewOpen] = useState(false);

  // Edit dialog state
  const [editViewOpen, setEditViewOpen] = useState(false);
  const [editClassOpen, setEditClassOpen] = useState(false);
  const [editFieldOpen, setEditFieldOpen] = useState(false);
  const [editOptionOpen, setEditOptionOpen] = useState(false);
  const [editingView, setEditingView] = useState<CrmView | null>(null);
  const [editingField, setEditingField] = useState<CrmField | null>(null);
  const [editingOption, setEditingOption] = useState<FieldOption | null>(null);

  // View drag state
  const [draggedViewId, setDraggedViewId] = useState<string | null>(null);
  const [viewDropIndicator, setViewDropIndicator] = useState<{
    viewId: string;
    position: "before" | "after";
  } | null>(null);

  // Get current selections
  const selectedClass = crm.classes.find((c) => c.id === selectedClassId);
  const selectedFields = selectedClassId
    ? crm.fields[selectedClassId] || []
    : [];
  const hierarchy = selectedClassId
    ? crm.hierarchy[selectedClassId] || []
    : [];

  // Get all fields across all classes for view editing
  const allFields = useMemo(() => {
    const fieldsMap = new Map<string, CrmField>();
    for (const classId of Object.keys(crm.fields)) {
      for (const field of crm.fields[classId]) {
        if (!fieldsMap.has(field.id)) {
          fieldsMap.set(field.id, field);
        }
      }
    }
    return Array.from(fieldsMap.values());
  }, [crm.fields]);

  // Keep editingField in sync with refetched crm data
  const resolvedEditingField = useMemo(() => {
    if (!editingField || !selectedClassId) return editingField;
    const fields = crm.fields[selectedClassId] || [];
    return fields.find((f) => f.id === editingField.id) || editingField;
  }, [editingField, selectedClassId, crm.fields]);

  // Get options for editing field
  const editingFieldOptions =
    selectedClassId && resolvedEditingField
      ? crm.options[selectedClassId]?.[resolvedEditingField.id] || []
      : [];

  // Invalidate crm data
  const invalidateCrm = () => {
    queryClient.invalidateQueries({ queryKey: ["crm", crmId] });
  };

  // Class mutations
  const createClassMutation = useMutation({
    mutationFn: ({ name, requests }: { name: string; requests?: string }) =>
      crmsApi.createClass(crmId, { name, requests }),
    onSuccess: (data) => {
      invalidateCrm();
      setSelectedClassId(data.data.id);
    },
    onError: (error) => {
      toast.error(getErrorMessage(error, "Failed to create class"));
    },
  });

  const updateClassMutation = useMutation({
    mutationFn: ({ classId, name, requests, title }: { classId: string; name: string; requests?: string; title?: string }) =>
      crmsApi.updateClass(crmId, classId, { name, requests, title }),
    onSuccess: invalidateCrm,
  });

  const deleteClassMutation = useMutation({
    mutationFn: (classId: string) => crmsApi.deleteClass(crmId, classId),
    onSuccess: () => {
      invalidateCrm();
      setSelectedClassId(crm.classes[0]?.id || null);
      setEditClassOpen(false);
    },
  });

  // Hierarchy mutation
  const setHierarchyMutation = useMutation({
    mutationFn: ({ classId, parents }: { classId: string; parents: string[] }) =>
      crmsApi.setHierarchy(crmId, classId, parents),
    onSuccess: invalidateCrm,
  });

  // Field mutations
  const createFieldMutation = useMutation({
    mutationFn: ({
      classId,
      name,
      fieldtype,
      rows,
    }: {
      classId: string;
      name: string;
      fieldtype: string;
      rows?: number;
    }) => crmsApi.createField(crmId, classId, { name, fieldtype, rows: rows?.toString() }),
    onSuccess: invalidateCrm,
  });

  const updateFieldMutation = useMutation({
    mutationFn: ({
      classId,
      fieldId,
      updates,
    }: {
      classId: string;
      fieldId: string;
      updates: Partial<CrmField>;
    }) =>
      crmsApi.updateField(crmId, classId, fieldId, {
        id: updates.id,
        name: updates.name,
        flags: updates.flags,
        rows: updates.rows?.toString(),
      }),
    onSuccess: (_, variables) => {
      // If the field was renamed, update editingField to point to the new ID
      if (variables.updates.id && variables.updates.id !== variables.fieldId) {
        setEditingField((prev) => prev ? { ...prev, id: variables.updates.id! } : prev);
      }
      invalidateCrm();
    },
    onError: (error) => {
      toast.error(getErrorMessage(error, "Failed to update field"));
    },
  });

  const deleteFieldMutation = useMutation({
    mutationFn: ({ classId, fieldId }: { classId: string; fieldId: string }) =>
      crmsApi.deleteField(crmId, classId, fieldId),
    onSuccess: () => {
      invalidateCrm();
      setEditFieldOpen(false);
    },
  });

  const reorderFieldsMutation = useMutation({
    mutationFn: ({ classId, order }: { classId: string; order: string[] }) =>
      crmsApi.reorderFields(crmId, classId, order),
    onSuccess: invalidateCrm,
    onError: (error) => {
      console.error("Reorder fields error:", error);
      toast.error(getErrorMessage(error, "Failed to reorder fields"));
    },
  });

  // Option mutations
  const createOptionMutation = useMutation({
    mutationFn: ({
      classId,
      fieldId,
      name,
      colour,
    }: {
      classId: string;
      fieldId: string;
      name: string;
      colour: string;
    }) =>
      crmsApi.createOption(crmId, classId, fieldId, { name, colour }),
    onSuccess: invalidateCrm,
  });

  const updateOptionMutation = useMutation({
    mutationFn: ({
      classId,
      fieldId,
      optionId,
      updates,
    }: {
      classId: string;
      fieldId: string;
      optionId: string;
      updates: { name?: string; colour?: string };
    }) =>
      crmsApi.updateOption(crmId, classId, fieldId, optionId, updates),
    onSuccess: invalidateCrm,
  });

  const deleteOptionMutation = useMutation({
    mutationFn: ({
      classId,
      fieldId,
      optionId,
    }: {
      classId: string;
      fieldId: string;
      optionId: string;
    }) => crmsApi.deleteOption(crmId, classId, fieldId, optionId),
    onSuccess: () => {
      invalidateCrm();
      setEditOptionOpen(false);
    },
  });

  // View mutations
  const createViewMutation = useMutation({
    mutationFn: ({
      name,
      viewtype,
      columns,
      rows,
      border,
      fields,
      sort,
      direction,
      classes,
    }: {
      name: string;
      viewtype: string;
      columns?: string;
      rows?: string;
      border?: string;
      fields?: string;
      sort?: string;
      direction?: "asc" | "desc";
      classes?: string;
    }) =>
      crmsApi.createView(crmId, {
        name,
        viewtype: viewtype as "board" | "list",
        fields: fields || allFields.map((f) => f.id).join(","),
        columns,
        rows,
        border,
        sort,
        direction,
        classes,
      }),
    onSuccess: invalidateCrm,
    onError: (error) => {
      toast.error(getErrorMessage(error, "Failed to create view"));
    },
  });

  const updateViewMutation = useMutation({
    mutationFn: ({
      viewId,
      updates,
      types,
    }: {
      viewId: string;
      updates?: Partial<CrmView>;
      types?: string[];
    }) => {
      // Always send all view fields to prevent backend from clearing unmentioned fields
      // (a.input() returns "" for missing fields, which passes the != None check)
      const currentView = crm.views.find((v) => v.id === viewId);
      const payload: Record<string, string> = {
        name: currentView?.name || "",
        viewtype: currentView?.viewtype || "board",
        filter: currentView?.filter || "",
        columns: currentView?.columns || "",
        rows: currentView?.rows || "",
        border: currentView?.border || "",
        fields: currentView?.fields || "",
        sort: currentView?.sort || "",
        direction: currentView?.direction || "asc",
      };
      if (updates) {
        if (updates.name !== undefined) payload.name = updates.name;
        if (updates.viewtype !== undefined) payload.viewtype = updates.viewtype;
        if (updates.filter !== undefined) payload.filter = updates.filter;
        if (updates.columns !== undefined) payload.columns = updates.columns;
        if (updates.rows !== undefined) payload.rows = updates.rows;
        if (updates.border !== undefined) payload.border = updates.border;
        if (updates.fields !== undefined) payload.fields = updates.fields;
        if (updates.sort !== undefined) payload.sort = updates.sort;
        if (updates.direction !== undefined) payload.direction = updates.direction;
      }
      if (types !== undefined) payload.classes = types.length === crm.classes.length ? "" : types.join(",");
      return crmsApi.updateView(crmId, viewId, payload);
    },
    onSuccess: invalidateCrm,
  });

  const deleteViewMutation = useMutation({
    mutationFn: (viewId: string) => crmsApi.deleteView(crmId, viewId),
    onSuccess: () => {
      invalidateCrm();
      setEditViewOpen(false);
    },
    onError: (error) => {
      toast.error(getErrorMessage(error, "Failed to delete view"));
    },
  });

  const reorderViewsMutation = useMutation({
    mutationFn: (order: string[]) =>
      crmsApi.reorderViews(crmId, order),
    onSuccess: invalidateCrm,
    onError: (error) => {
      toast.error(getErrorMessage(error, "Failed to reorder views"));
    },
  });

  // Handlers
  const handleEditView = (view: CrmView) => {
    setEditingView(view);
    setEditViewOpen(true);
  };

  const handleEditField = (field: CrmField) => {
    setEditingField(field);
    setEditFieldOpen(true);
  };

  const handleEditOption = (option: FieldOption) => {
    setEditingOption(option);
    setEditOptionOpen(true);
  };

  // Create class with chained API calls
  const handleCreateClass = async (name: string, parents: string[], pendingFields: PendingField[], mergeRequests: boolean) => {
    const result = await createClassMutation.mutateAsync({ name, requests: mergeRequests ? "merge" : undefined });
    const classId = result.data?.id;
    if (!classId) return;

    if (parents.length > 0) {
      await setHierarchyMutation.mutateAsync({ classId, parents });
    }

    // Create each non-title field (title is auto-created by the backend)
    for (const field of pendingFields) {
      if (field.id === "title") continue;
      const fieldResult = await createFieldMutation.mutateAsync({
        classId,
        name: field.name,
        fieldtype: field.fieldtype,
        rows: field.rows,
      });
      // Create options for enumerated fields
      if (field.fieldtype === "enumerated" && field.options && fieldResult.data) {
        for (const opt of field.options) {
          await createOptionMutation.mutateAsync({
            classId,
            fieldId: fieldResult.data.id,
            name: opt.name,
            colour: opt.colour,
          });
        }
      }
    }
  };

  // View drag handlers
  const handleViewDragStart = (e: React.DragEvent, viewId: string) => {
    setDraggedViewId(viewId);
    e.dataTransfer.effectAllowed = "move";
    e.dataTransfer.setData("text/plain", viewId);
  };

  const handleViewDragEnd = () => {
    setDraggedViewId(null);
    setViewDropIndicator(null);
  };

  const handleViewDragOver = (e: React.DragEvent, viewId: string) => {
    e.preventDefault();
    if (viewId === draggedViewId) return;
    const rect = e.currentTarget.getBoundingClientRect();
    const midY = rect.top + rect.height / 2;
    const position = e.clientY < midY ? "before" : "after";
    setViewDropIndicator({ viewId, position });
  };

  const handleViewDragLeave = () => {
    setViewDropIndicator(null);
  };

  const handleViewDrop = (e: React.DragEvent, targetViewId: string) => {
    e.preventDefault();
    if (!draggedViewId || draggedViewId === targetViewId) return;

    const currentOrder = crm.views.map((v) => v.id);
    const draggedIndex = currentOrder.indexOf(draggedViewId);
    const targetIndex = currentOrder.indexOf(targetViewId);
    if (draggedIndex === -1 || targetIndex === -1) return;

    const newOrder = [...currentOrder];
    newOrder.splice(draggedIndex, 1);
    const insertIndex = viewDropIndicator?.position === "after"
      ? currentOrder.indexOf(targetViewId) - (draggedIndex < targetIndex ? 1 : 0) + 1
      : currentOrder.indexOf(targetViewId) - (draggedIndex < targetIndex ? 1 : 0);
    newOrder.splice(insertIndex, 0, draggedViewId);

    reorderViewsMutation.mutate(newOrder);
    setDraggedViewId(null);
    setViewDropIndicator(null);
  };

  return (
    <div className="flex h-full">
      {/* Editor panel (left) */}
      <div className="w-80 border-r flex flex-col overflow-hidden">
        <div className="flex-1 overflow-auto p-4 space-y-6">
          {/* Views Section */}
          <section>
            <div className="flex items-center justify-between mb-2">
              <Label className="text-sm font-medium">Views</Label>
              <Button
                variant="ghost"
                size="sm"
                onClick={() => setAddViewOpen(true)}
              >
                <Plus className="size-4" />
              </Button>
            </div>
            <div className="space-y-1">
              {crm.views.map((view) => (
                <div key={view.id}>
                  {viewDropIndicator?.viewId === view.id && viewDropIndicator.position === "before" && (
                    <div className="h-0.5 bg-primary mx-3 rounded-full" />
                  )}
                  <div
                    draggable
                    onDragStart={(e) => handleViewDragStart(e, view.id)}
                    onDragEnd={handleViewDragEnd}
                    onDragOver={(e) => handleViewDragOver(e, view.id)}
                    onDragLeave={handleViewDragLeave}
                    onDrop={(e) => handleViewDrop(e, view.id)}
                    className={`flex items-center gap-2 px-3 py-2 text-sm rounded-md hover:bg-muted transition-colors cursor-grab ${
                      draggedViewId === view.id ? "opacity-50" : ""
                    }`}
                  >
                    <GripVertical className="size-4 text-muted-foreground shrink-0" />
                    <button
                      type="button"
                      onClick={() => handleEditView(view)}
                      className="flex-1 text-left"
                    >
                      <span className="font-medium">{view.name}</span>
                    </button>
                  </div>
                  {viewDropIndicator?.viewId === view.id && viewDropIndicator.position === "after" && (
                    <div className="h-0.5 bg-primary mx-3 rounded-full" />
                  )}
                </div>
              ))}
            </div>
          </section>

          <hr className="border-border" />

          {/* Classes Section */}
          <section>
            <div className="flex items-center justify-between mb-2">
              <Label className="text-sm font-medium">Classes</Label>
              <Button
                variant="ghost"
                size="sm"
                onClick={() => setAddClassOpen(true)}
              >
                <Plus className="size-4" />
              </Button>
            </div>
            <div className="space-y-1">
              {crm.classes.map((cls) => (
                <button
                  key={cls.id}
                  onClick={() => {
                    setSelectedClassId(cls.id);
                    setEditClassOpen(true);
                  }}
                  className="w-full text-left px-3 py-2 text-sm rounded-md transition-colors hover:bg-muted flex items-center gap-2"
                >
                  <Blocks className="size-4 text-muted-foreground shrink-0" />
                  {cls.name}
                </button>
              ))}
            </div>
          </section>

        </div>
      </div>

      {/* Preview panel (right) */}
      <div className="flex-1 overflow-hidden">
        <DesignPreview
          classes={crm.classes}
          fields={crm.fields}
          options={crm.options}
          views={crm.views}
          selectedClassId={selectedClassId}
        />
      </div>

      {/* Add view (create mode) */}
      <ViewSheet
        open={addViewOpen}
        onOpenChange={setAddViewOpen}
        mode="create"
        fields={allFields}
        classes={crm.classes}
        onCreate={async (name, viewtype, columns, rows, selectedFields, sort, direction, selectedClasses, border) => {
          await createViewMutation.mutateAsync({
            name,
            viewtype,
            columns: columns || undefined,
            rows: rows || undefined,
            border: border || undefined,
            fields: selectedFields.join(","),
            sort: sort || undefined,
            direction: direction as "asc" | "desc",
            classes: selectedClasses.length === crm.classes.length ? "" : selectedClasses.join(","),
          });
        }}
      />

      {/* Add class (create mode) */}
      <ClassSheet
        open={addClassOpen}
        onOpenChange={setAddClassOpen}
        mode="create"
        classes={crm.classes}
        onCreate={handleCreateClass}
      />

      <AddFieldDialog
        open={addFieldOpen}
        onOpenChange={setAddFieldOpen}
        onAdd={async (name, fieldtype, rows, options) => {
          if (selectedClassId) {
            try {
              const result = await createFieldMutation.mutateAsync({
                classId: selectedClassId,
                name,
                fieldtype,
                rows,
              });
              // Create options for enumerated fields
              if (fieldtype === "enumerated" && options && result.data) {
                for (const opt of options) {
                  await createOptionMutation.mutateAsync({
                    classId: selectedClassId,
                    fieldId: result.data.id,
                    name: opt.name,
                    colour: opt.colour,
                  });
                }
              }
            } catch (error) {
              toast.error(getErrorMessage(error, "Failed to create field"));
              throw error;
            }
          }
        }}
      />

      <OptionDialog
        open={addOptionOpen}
        onOpenChange={setAddOptionOpen}
        onAdd={async (name, colour) => {
          if (selectedClassId && editingField) {
            try {
              await createOptionMutation.mutateAsync({
                classId: selectedClassId,
                fieldId: editingField.id,
                name,
                colour,
              });
            } catch (error) {
              toast.error(getErrorMessage(error, "Failed to create option"));
              throw error;
            }
          }
        }}
      />

      {/* Edit view */}
      <ViewSheet
        open={editViewOpen}
        onOpenChange={setEditViewOpen}
        view={editingView}
        fields={allFields}
        classes={crm.classes}
        onUpdate={(updates) => {
          if (editingView) {
            updateViewMutation.mutate({ viewId: editingView.id, updates });
          }
        }}
        onUpdateClasses={(classes) => {
          if (editingView) {
            updateViewMutation.mutate({ viewId: editingView.id, types: classes });
          }
        }}
        onDelete={() => {
          if (editingView) {
            deleteViewMutation.mutate(editingView.id);
          }
        }}
      />

      {/* Edit class */}
      <ClassSheet
        open={editClassOpen}
        onOpenChange={setEditClassOpen}
        cls={selectedClass || null}
        classes={crm.classes}
        hierarchy={hierarchy}
        fields={selectedFields}
        onUpdate={(name, requests, title) => {
          if (selectedClassId) {
            updateClassMutation.mutate({ classId: selectedClassId, name, requests, title });
          }
        }}
        onUpdateHierarchy={(parents) => {
          if (selectedClassId) {
            setHierarchyMutation.mutate({ classId: selectedClassId, parents });
          }
        }}
        onDelete={() => {
          if (selectedClassId) {
            deleteClassMutation.mutate(selectedClassId);
          }
        }}
        onAddField={() => setAddFieldOpen(true)}
        onEditField={handleEditField}
        onReorderFields={(order) => {
          if (selectedClassId) {
            reorderFieldsMutation.mutate({ classId: selectedClassId, order });
          }
        }}
      />

      <EditFieldDialog
        open={editFieldOpen}
        onOpenChange={setEditFieldOpen}
        field={resolvedEditingField}
        isSystemField={resolvedEditingField?.id === selectedClass?.title}
        options={editingFieldOptions}
        onUpdate={(updates) => {
          if (selectedClassId && resolvedEditingField) {
            if (updates.id) {
              return updateFieldMutation.mutateAsync({
                classId: selectedClassId,
                fieldId: resolvedEditingField.id,
                updates,
              }).then(() => {});
            }
            updateFieldMutation.mutate({
              classId: selectedClassId,
              fieldId: resolvedEditingField.id,
              updates,
            });
          }
        }}
        onDelete={() => {
          if (selectedClassId && resolvedEditingField) {
            deleteFieldMutation.mutate({
              classId: selectedClassId,
              fieldId: resolvedEditingField.id,
            });
          }
        }}
        onAddOption={() => setAddOptionOpen(true)}
        onEditOption={handleEditOption}
        onDeleteOption={(optionId) => {
          if (selectedClassId && resolvedEditingField) {
            deleteOptionMutation.mutate({
              classId: selectedClassId,
              fieldId: resolvedEditingField.id,
              optionId,
            });
          }
        }}
        onReorderOptions={() => {}}
      />

      <OptionDialog
        open={editOptionOpen}
        onOpenChange={setEditOptionOpen}
        option={editingOption}
        onUpdate={(updates) => {
          if (selectedClassId && editingField && editingOption) {
            updateOptionMutation.mutate({
              classId: selectedClassId,
              fieldId: editingField.id,
              optionId: editingOption.id,
              updates,
            });
          }
        }}
        onDelete={() => {
          if (selectedClassId && editingField && editingOption) {
            deleteOptionMutation.mutate({
              classId: selectedClassId,
              fieldId: editingField.id,
              optionId: editingOption.id,
            });
          }
        }}
      />
    </div>
  );
}
