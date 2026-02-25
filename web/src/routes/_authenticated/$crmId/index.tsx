// Mochi CRM: CRM page with board and tree views
// Copyright Alistair Cunningham 2026

import { useState, useMemo, useCallback, useEffect, useRef } from "react";
import { createFileRoute, Link, useNavigate, useRouter } from "@tanstack/react-router";
import { useQuery, useMutation, useQueryClient } from "@tanstack/react-query";
import {
  GeneralError,
  Main,
  PageHeader,
  usePageTitle,
  Button,
  DropdownMenu,
  DropdownMenuContent,
  DropdownMenuItem,
  DropdownMenuTrigger,
  Switch,
  useSearch,
  toast,
} from "@mochi/common";
import { Columns3, Ellipsis, Users, GripVertical, Plus, Settings, Settings2, SlidersHorizontal, X } from "lucide-react";
import crmsApi from "@/api/crms";
import type { CrmDetails, CrmObject, SortState } from "@/types";
import { canDesign, canWrite } from "@/lib/access";
import { BoardContainer } from "@/features/board/components";
import { TreeView } from "@/features/tree";
import { FilterBar, type FilterState } from "@/features/views";
import {
  CreateObjectDialog,
  ObjectDetailPanel,
} from "@/features/objects/components";
import { useKeyboardShortcuts } from "@/hooks/use-keyboard-shortcuts";
import { useCrmWebsocket } from "@/hooks/use-crm-websocket";
import { KeyboardShortcutsHelp } from "@/components/keyboard-shortcuts-help";
import { ViewOptionsBar } from "@/components/view-options-bar";
import { OptionDialog } from "@/features/editor/components/option-dialog";

interface SearchParams {
  view?: string;
}

export const Route = createFileRoute("/_authenticated/$crmId/")({
  validateSearch: (search: Record<string, unknown>): SearchParams => ({
    view: typeof search.view === "string" ? search.view : undefined,
  }),
  loader: async ({ params }) => {
    const crmResponse = await crmsApi.get(params.crmId);
    return { crm: crmResponse.data };
  },
  component: CrmPage,
  errorComponent: ({ error }) => <GeneralError error={error} />,
});

function CrmPage() {
  const { crm } = Route.useLoaderData() as {
    crm: CrmDetails;
  };
  const params = Route.useParams();
  const search = Route.useSearch();
  const navigate = useNavigate();
  const router = useRouter();

  const access = crm.crm.access;

  usePageTitle(crm.crm.name);
  useCrmWebsocket(crm.crm.fingerprint);

  // Disable global Ctrl+K search shortcut so we can use it for view options
  const { setShortcutEnabled } = useSearch();
  useEffect(() => {
    setShortcutEnabled(false);
    return () => setShortcutEnabled(true);
  }, [setShortcutEnabled]);

  const [selectedObjectId, setSelectedObjectId] = useState<string | null>(null);
  const [createDialogOpen, setCreateDialogOpen] = useState(false);
  const [createDefaultFields, setCreateDefaultFields] = useState<
    { field: string; value: string }[] | undefined
  >();
  const [createDefaultParent, setCreateDefaultParent] = useState<string | undefined>();
  const [createChildClasses, setCreateChildClasses] = useState<string[] | undefined>();
  const [showShortcutsHelp, setShowShortcutsHelp] = useState(false);
  const [showViewOptions, setShowViewOptions] = useState(() => {
    const saved = localStorage.getItem("crms-view-options-expanded");
    return saved !== "false";
  });
  const [selectedCardIndex, setSelectedCardIndex] = useState(-1);
  const [addColumnDialogOpen, setAddColumnDialogOpen] = useState(false);
  const [isReorderingColumns, setIsReorderingColumns] = useState(false);
  const [pendingColumnOrder, setPendingColumnOrder] = useState<string[] | null>(null);
  const [showBoardHint, setShowBoardHint] = useState(() => {
    return localStorage.getItem("crms-hint-double-click-dismissed") !== "true";
  });

  const dismissBoardHint = () => {
    setShowBoardHint(false);
    localStorage.setItem("crms-hint-double-click-dismissed", "true");
  };

  // Persist view options bar state
  useEffect(() => {
    localStorage.setItem("crms-view-options-expanded", String(showViewOptions));
  }, [showViewOptions]);

  // View state - initialize from URL or first view
  const defaultViewId = crm.views[0]?.id || "board";
  const initialViewId = search.view && crm.views.some((v) => v.id === search.view)
    ? search.view
    : defaultViewId;
  const [activeViewId, setActiveViewId] = useState(initialViewId);
  const activeView =
    crm.views.find((v) => v.id === activeViewId) || crm.views[0];

  // Deduplicated field list across all classes (for sort dropdown)
  const allFields = useMemo(() => {
    const seen = new Set<string>();
    const result: typeof crm.fields[string] = [];
    for (const fields of Object.values(crm.fields)) {
      for (const f of fields) {
        if (!seen.has(f.id)) {
          seen.add(f.id);
          result.push(f);
        }
      }
    }
    return result;
  }, [crm.fields]);

  // Sync URL when view changes
  useEffect(() => {
    const newView = activeViewId === defaultViewId ? undefined : activeViewId;
    if (search.view !== newView) {
      navigate({
        to: ".",
        search: { view: newView },
        replace: true,
      });
    }
  }, [activeViewId, defaultViewId, search.view, navigate]);

  // Filter state
  const [filters, setFilters] = useState<FilterState>({
    search: "",
    watched: false,
  });

  // Sort state for list view (default to rank/manual order)
  const [sort, setSort] = useState<SortState | null>({ field: "rank", direction: "asc" });

  const queryClient = useQueryClient();

  // Load objects
  const { data: objectListData } = useQuery({
    queryKey: ["objects", params.crmId],
    queryFn: async () => {
      const response = await crmsApi.listObjects(params.crmId);
      return response.data;
    },
  });
  const objectsData = objectListData?.objects;
  const watchedIds = objectListData?.watched;

  // When CRM is empty and no view was specified in URL, switch to the companies view
  const didAutoSwitch = useRef(false);
  useEffect(() => {
    if (didAutoSwitch.current || search.view) return;
    if (objectsData && objectsData.length === 0) {
      const companiesView = crm.views.find((v) => v.classes?.includes("company"));
      if (companiesView && companiesView.id !== activeViewId) {
        didAutoSwitch.current = true;
        setActiveViewId(companiesView.id);
      }
    }
  }, [objectsData, crm.views, search.view, activeViewId]);

  // Load people for resolving user field values to names
  const { data: peopleData } = useQuery({
    queryKey: ["people", params.crmId],
    queryFn: async () => {
      const response = await crmsApi.listPeople(params.crmId);
      return response.data.people;
    },
  });

  // Create a map of user ID to name for quick lookups
  const peopleMap = useMemo(() => {
    const map: Record<string, string> = {};
    for (const person of peopleData || []) {
      map[person.id] = person.name;
    }
    return map;
  }, [peopleData]);

  // Check if an object is a descendant of a given ancestor
  const isDescendant = (obj: CrmObject, ancestorId: string, allObjects: CrmObject[]): boolean => {
    let current = obj.parent;
    while (current) {
      if (current === ancestorId) return true;
      const parent = allObjects.find((o) => o.id === current);
      current = parent?.parent || "";
    }
    return false;
  };

  // Move object mutation
  const moveMutation = useMutation({
    mutationFn: async ({
      objectId,
      field,
      value,
      rank,
      rowField: rf,
      rowValue,
      scopeParent,
      promote,
    }: {
      objectId: string;
      field: string;
      value: string;
      rank?: number;
      rowField?: string;
      rowValue?: string;
      scopeParent?: string;
      promote?: boolean;
    }) => {
      return crmsApi.moveObject(params.crmId, objectId, {
        field,
        value,
        rank,
        row_field: rf,
        row_value: rowValue,
        scope_parent: scopeParent,
        promote: promote ? "true" : undefined,
      });
    },
    onMutate: async ({ objectId, field, value, rank, rowField: rf, rowValue, scopeParent, promote }) => {
      // Optimistically update the UI
      await queryClient.cancelQueries({
        queryKey: ["objects", params.crmId],
      });

      const previousData = queryClient.getQueryData<{ objects: CrmObject[]; watched?: string[] }>([
        "objects",
        params.crmId,
      ]);

      queryClient.setQueryData<{ objects: CrmObject[]; watched?: string[] }>(
        ["objects", params.crmId],
        (old) => {
          if (!old) return old;

          // Sibling reorder: renumber siblings sequentially
          if (scopeParent && rank) {
            const siblings = old.objects
              .filter((o) => o.parent === scopeParent && o.id !== objectId)
              .sort((a, b) => (a.rank || 0) - (b.rank || 0));
            const movedObj = old.objects.find((o) => o.id === objectId);
            if (movedObj) {
              siblings.splice(rank - 1, 0, movedObj);
              const rankMap: Record<string, number> = {};
              siblings.forEach((s, i) => { rankMap[s.id] = i + 1; });
              return {
                ...old,
                objects: old.objects.map((obj) =>
                  rankMap[obj.id] !== undefined ? { ...obj, rank: rankMap[obj.id] } : obj,
                ),
              };
            }
          }

          return {
            ...old,
            objects: old.objects.map((obj) => {
              if (obj.id === objectId) {
                const updatedValues = { ...obj.values, [field]: value };
                if (rf && rowValue !== undefined) {
                  updatedValues[rf] = rowValue;
                }
                return {
                  ...obj,
                  rank: rank ?? obj.rank,
                  values: updatedValues,
                  ...(promote ? { parent: "" } : {}),
                };
              }
              // Cascade status/row changes to descendants
              if (field && isDescendant(obj, objectId, old.objects)) {
                const updatedValues = { ...obj.values, [field]: value };
                if (rf && rowValue !== undefined) {
                  updatedValues[rf] = rowValue;
                }
                return { ...obj, values: updatedValues };
              }
              return obj;
            }),
          };
        },
      );

      return { previousData };
    },
    onError: (_err, _variables, context) => {
      // Rollback on error
      if (context?.previousData) {
        queryClient.setQueryData(
          ["objects", params.crmId],
          context.previousData,
        );
      }
    },
    onSettled: () => {
      queryClient.invalidateQueries({
        queryKey: ["objects", params.crmId],
      });
    },
  });

  // Reparent object mutation
  const reparentMutation = useMutation({
    mutationFn: async ({
      objectId,
      parentId,
    }: {
      objectId: string;
      parentId: string | null;
    }) => {
      return crmsApi.updateObject(params.crmId, objectId, {
        parent: parentId || "",
      });
    },
    onMutate: async ({ objectId, parentId }) => {
      await queryClient.cancelQueries({
        queryKey: ["objects", params.crmId],
      });

      const previousData = queryClient.getQueryData<{ objects: CrmObject[]; watched?: string[] }>([
        "objects",
        params.crmId,
      ]);

      queryClient.setQueryData<{ objects: CrmObject[]; watched?: string[] }>(
        ["objects", params.crmId],
        (old) => {
          if (!old) return old;
          const newParent = parentId ? old.objects.find((o) => o.id === parentId) : null;
          const sf = activeView?.columns || "";
          const rf = activeView?.rows || "";
          return {
            ...old,
            objects: old.objects.map((obj) => {
              if (obj.id !== objectId) return obj;
              const updated = { ...obj, parent: parentId || "" };
              if (newParent && sf) {
                updated.values = { ...updated.values, [sf]: newParent.values[sf] || "" };
                if (rf) updated.values[rf] = newParent.values[rf] || "";
              }
              return updated;
            }),
          };
        },
      );

      return { previousData };
    },
    onError: (_err, _variables, context) => {
      if (context?.previousData) {
        queryClient.setQueryData(
          ["objects", params.crmId],
          context.previousData,
        );
      }
    },
    onSettled: () => {
      queryClient.invalidateQueries({
        queryKey: ["objects", params.crmId],
      });
    },
  });

  // Delete column (option) mutation
  const deleteColumnMutation = useMutation({
    mutationFn: async ({
      classId,
      fieldId,
      optionId,
    }: {
      classId: string;
      fieldId: string;
      optionId: string;
    }) => {
      return crmsApi.deleteOption(params.crmId, classId, fieldId, optionId);
    },
    onSuccess: () => {
      router.invalidate();
    },
  });

  // Rename column (option) mutation
  const renameColumnMutation = useMutation({
    mutationFn: async ({
      classId,
      fieldId,
      optionId,
      name,
    }: {
      classId: string;
      fieldId: string;
      optionId: string;
      name: string;
    }) => {
      return crmsApi.updateOption(params.crmId, classId, fieldId, optionId, { name });
    },
    onSuccess: () => {
      router.invalidate();
    },
  });

  // Create column (option) mutation
  const createColumnMutation = useMutation({
    mutationFn: async ({
      classId,
      fieldId,
      name,
      colour,
    }: {
      classId: string;
      fieldId: string;
      name: string;
      colour: string;
    }) => {
      return crmsApi.createOption(params.crmId, classId, fieldId, { name, colour });
    },
    onSuccess: () => {
      router.invalidate();
    },
  });

  // Reorder columns (options) mutation
  const reorderColumnsMutation = useMutation({
    mutationFn: async ({
      classId,
      fieldId,
      order,
    }: {
      classId: string;
      fieldId: string;
      order: string[];
    }) => {
      return crmsApi.reorderOptions(params.crmId, classId, fieldId, order);
    },
    onSuccess: () => {
      router.invalidate();
      setIsReorderingColumns(false);
      setPendingColumnOrder(null);
    },
  });

  // Filter objects
  const filteredObjects = useMemo(() => {
    let result = objectsData || [];

    // Apply view's class filter (if view has specific classes selected)
    const viewClasses = activeView?.classes || [];
    if (viewClasses.length > 0) {
      result = result.filter((obj) => viewClasses.includes(obj.class));
    }

    // Apply search filter
    if (filters.search) {
      const searchLower = filters.search.toLowerCase();
      result = result.filter((obj) =>
        Object.values(obj.values).some(
          (v) => typeof v === "string" && v.toLowerCase().includes(searchLower)
        )
      );
    }

    // Apply watched filter
    if (filters.watched && watchedIds) {
      const watchedSet = new Set(watchedIds);
      result = result.filter((obj) => watchedSet.has(obj.id));
    }

    return result;
  }, [objectsData, watchedIds, filters, activeView?.classes]);

  // Keyboard navigation helpers
  const handleSelectNext = useCallback(() => {
    if (filteredObjects.length === 0) return;
    const currentIndex = selectedObjectId
      ? filteredObjects.findIndex((obj) => obj.id === selectedObjectId)
      : selectedCardIndex;
    const nextIndex = currentIndex + 1 >= filteredObjects.length ? 0 : currentIndex + 1;
    setSelectedCardIndex(nextIndex);
    if (selectedObjectId) {
      setSelectedObjectId(filteredObjects[nextIndex].id);
    }
  }, [filteredObjects, selectedCardIndex, selectedObjectId]);

  const handleSelectPrevious = useCallback(() => {
    if (filteredObjects.length === 0) return;
    const currentIndex = selectedObjectId
      ? filteredObjects.findIndex((obj) => obj.id === selectedObjectId)
      : selectedCardIndex;
    const prevIndex = currentIndex <= 0 ? filteredObjects.length - 1 : currentIndex - 1;
    setSelectedCardIndex(prevIndex);
    if (selectedObjectId) {
      setSelectedObjectId(filteredObjects[prevIndex].id);
    }
  }, [filteredObjects, selectedCardIndex, selectedObjectId]);

  const handleOpenSelected = useCallback(() => {
    if (selectedCardIndex >= 0 && selectedCardIndex < filteredObjects.length) {
      setSelectedObjectId(filteredObjects[selectedCardIndex].id);
    }
  }, [selectedCardIndex, filteredObjects]);

  const handleSwitchView = useCallback(
    (index: number) => {
      if (index < crm.views.length) {
        setActiveViewId(crm.views[index].id);
        setSort({ field: "rank", direction: "asc" });
      }
    },
    [crm.views],
  );

  // Get the column and row fields for the current view
  const columnField = activeView?.columns || "";
  const rowField = activeView?.rows || "";

  // Get default column value (first option of column field for the view's class)
  const viewClasses = activeView?.classes || [];
  const getDefaultColumnValue = useCallback(() => {
    const effectiveType = viewClasses.length > 0
      ? viewClasses[0]
      : crm.classes[0]?.id;
    if (effectiveType && crm.options[effectiveType]?.[columnField]?.length > 0) {
      return [{ field: columnField, value: crm.options[effectiveType][columnField][0].id }];
    }
    return undefined;
  }, [crm.classes, crm.options, columnField, viewClasses]);

  const handleOpenCreateDialog = useCallback(() => {
    if (crm.classes.length === 0) {
      toast.error("Please add one or more classes to the CRM design.");
      return;
    }
    setCreateDefaultFields(getDefaultColumnValue());
    setCreateDialogOpen(true);
  }, [crm.classes.length, getDefaultColumnValue]);

  // Keyboard shortcuts
  useKeyboardShortcuts({
    onCreateNew: handleOpenCreateDialog,
    onFocusSearch: () => setShowViewOptions((prev) => !prev),
    onSwitchView: handleSwitchView,
    onSelectNext: handleSelectNext,
    onSelectPrevious: handleSelectPrevious,
    onOpenSelected: handleOpenSelected,
    onEditSelected: handleOpenSelected,
    onClose: () => {
      if (selectedObjectId) {
        setSelectedObjectId(null);
      } else {
        setSelectedCardIndex(-1);
      }
    },
    onShowHelp: () => setShowShortcutsHelp(true),
    enabled: !createDialogOpen,
  });

  const handleCardClick = (object: CrmObject) => {
    setSelectedObjectId(object.id);
  };

  const handleCreateClick = (columnValue: string, rowValue?: string) => {
    if (crm.classes.length === 0) {
      toast.error("Please add one or more classes to the CRM design.");
      return;
    }
    const fields = [{ field: columnField, value: columnValue }];
    if (rowValue !== undefined && rowField) {
      fields.push({ field: rowField, value: rowValue });
    }
    setCreateDefaultFields(fields);
    setCreateDefaultParent(undefined);
    setCreateChildClasses(undefined);
    setCreateDialogOpen(true);
  };

  // Double-click on an object: create a child of that object
  const handleCreateChild = (parent: CrmObject) => {
    setSelectedObjectId(null);
    // Find all classes that can be children of this object's class
    const childClasses = crm.classes
      .filter((c) => (crm.hierarchy[c.id] || []).includes(parent.class))
      .map((c) => c.id);
    if (childClasses.length === 0) return;
    // Pre-fill column fields from the parent's values
    const fields: { field: string; value: string }[] = [];
    if (columnField && parent.values[columnField]) {
      fields.push({ field: columnField, value: parent.values[columnField] });
    }
    setCreateDefaultFields(fields.length > 0 ? fields : undefined);
    setCreateDefaultParent(parent.id);
    setCreateChildClasses(childClasses);
    setCreateDialogOpen(true);
  };

  const handleMoveObject = (objectId: string, newValue: string, newRank?: number, newRow?: string, scopeParent?: string, promote?: boolean) => {
    moveMutation.mutate({
      objectId,
      field: columnField,
      value: newValue,
      rank: newRank,
      rowField: newRow !== undefined ? rowField : undefined,
      rowValue: newRow,
      scopeParent,
      promote,
    });
  };

  const handleReparent = (objectId: string, newParentId: string | null) => {
    reparentMutation.mutate({ objectId, parentId: newParentId });
  };

  const handleReorder = (objectId: string, newRank: number) => {
    // Use move mutation with just rank (no field/value change)
    moveMutation.mutate({ objectId, field: "", value: "", rank: newRank });
  };

  const handleDeleteColumn = async (classId: string, fieldId: string, optionId: string) => {
    await deleteColumnMutation.mutateAsync({ classId, fieldId, optionId });
  };

  const handleRenameColumn = async (classId: string, fieldId: string, optionId: string, newName: string) => {
    await renameColumnMutation.mutateAsync({ classId, fieldId, optionId, name: newName });
  };

  const handleObjectCreated = () => {
    // Object created successfully, queries will be invalidated by the mutation
  };

  const handleViewChange = (viewId: string) => {
    setActiveViewId(viewId);
    // Reset sort when switching views
    setSort({ field: "rank", direction: "asc" });
  };

  const handleAddColumn = (name: string, colour: string) => {
    const defaultClass = crm.classes[0];
    if (!defaultClass) return;
    createColumnMutation.mutate({
      classId: defaultClass.id,
      fieldId: columnField,
      name,
      colour,
    });
  };

  const handleReorderColumns = (order: string[]) => {
    setPendingColumnOrder(order);
  };

  const handleSaveColumnOrder = () => {
    const defaultClass = crm.classes[0];
    if (!defaultClass || !pendingColumnOrder) return;
    reorderColumnsMutation.mutate({
      classId: defaultClass.id,
      fieldId: columnField,
      order: pendingColumnOrder,
    });
  };

  const handleCancelReorder = () => {
    setIsReorderingColumns(false);
    setPendingColumnOrder(null);
  };

  return (
    <>
      <PageHeader
        title={crm.crm.name}
        icon={<Users className="size-4 md:size-5" />}
        actions={
          <div className="flex items-center gap-2">
            <FilterBar
              filters={filters}
              onFilterChange={setFilters}
            />
            {canWrite(access) && (
              <Button variant="ghost" size="icon" onClick={handleOpenCreateDialog} title="Create (C)">
                <Plus className="size-4" />
              </Button>
            )}
            <DropdownMenu>
              <DropdownMenuTrigger asChild>
                <Button variant="ghost" size="icon">
                  <Ellipsis className="size-4" />
                </Button>
              </DropdownMenuTrigger>
              <DropdownMenuContent align="end">
                <DropdownMenuItem
                  onSelect={(e) => e.preventDefault()}
                >
                  <SlidersHorizontal className="size-4 mr-2" />
                  View options
                  <Switch
                    className="ml-auto"
                    checked={showViewOptions}
                    onCheckedChange={setShowViewOptions}
                  />
                </DropdownMenuItem>
                {canDesign(access) && activeView?.viewtype !== "list" && (
                  <>
                    <DropdownMenuItem onClick={() => setAddColumnDialogOpen(true)}>
                      <Columns3 className="size-4 mr-2" />
                      Add column
                    </DropdownMenuItem>
                    <DropdownMenuItem onClick={() => setIsReorderingColumns(true)}>
                      <GripVertical className="size-4 mr-2" />
                      Re-order columns
                    </DropdownMenuItem>
                  </>
                )}
                {canDesign(access) && (
                  <DropdownMenuItem asChild>
                    <Link
                      to="/$crmId/design"
                      params={{ crmId: params.crmId }}
                    >
                      <Settings2 className="size-4 mr-2" />
                      Design
                    </Link>
                  </DropdownMenuItem>
                )}
                <DropdownMenuItem asChild>
                  <Link
                    to="/$crmId/settings"
                    params={{ crmId: params.crmId }}
                  >
                    <Settings className="size-4 mr-2" />
                    Settings
                  </Link>
                </DropdownMenuItem>
              </DropdownMenuContent>
            </DropdownMenu>
          </div>
        }
      />
      {showViewOptions && (
        <ViewOptionsBar
          crm={crm}
          fields={allFields}
          filters={filters}
          onFilterChange={setFilters}
          activeViewId={activeViewId}
          onViewChange={handleViewChange}
          sort={sort}
          onSortChange={setSort}
          showSort
        />
      )}
      {isReorderingColumns && (
        <div className="flex items-center justify-between px-4 py-2 bg-muted border-b">
          <span className="text-sm text-muted-foreground">
            Drag columns to re-order them
          </span>
          <div className="flex items-center gap-2">
            <Button variant="outline" size="sm" onClick={handleCancelReorder}>
              Cancel
            </Button>
            <Button
              size="sm"
              onClick={handleSaveColumnOrder}
              disabled={!pendingColumnOrder || reorderColumnsMutation.isPending}
            >
              Save
            </Button>
          </div>
        </div>
      )}
      {showBoardHint && !isReorderingColumns && activeView?.viewtype !== "list" && (
        <div className="flex items-center justify-between px-4 py-2 bg-muted border-b">
          <span className="text-sm text-muted-foreground">
            Double click on a column to add content
          </span>
          <Button
            variant="ghost"
            size="icon"
            className="size-6"
            onClick={dismissBoardHint}
          >
            <X className="size-4" />
          </Button>
        </div>
      )}
      <Main fluid className="flex flex-col min-h-0 min-w-0 flex-1 !p-0">
        {/* Content area */}
        <div className={activeView?.viewtype === "list" ? "flex-1 min-h-0 overflow-auto" : "flex-1 min-h-0 overflow-x-auto"}>
          {activeView?.viewtype === "list" ? (
            <div className="p-4">
              <TreeView
                crm={crm}
                crmId={params.crmId}
                objects={filteredObjects}
                peopleMap={peopleMap}
                viewFields={activeView?.fields}
                sort={sort}
                onCardClick={handleCardClick}
                onReparent={canWrite(access) ? handleReparent : undefined}
                onReorder={canWrite(access) ? handleReorder : undefined}
                onCreateClick={canWrite(access) ? handleOpenCreateDialog : undefined}
              />
            </div>
          ) : (
            <div className="px-4 w-fit min-w-full">
              <BoardContainer
                crm={crm}
                objects={filteredObjects}
                statusField={columnField}
                rowField={rowField}
                borderField={activeView?.border}
                viewFields={activeView?.fields}
                viewClasses={activeView?.classes}
                sort={sort}
                peopleMap={peopleMap}
                onCardClick={handleCardClick}
                onCardDoubleClick={canWrite(access) ? handleCreateChild : undefined}
                onCreateClick={canWrite(access) ? handleCreateClick : undefined}
                onMoveObject={canWrite(access) ? handleMoveObject : undefined}
                onReparentObject={canWrite(access) ? handleReparent : undefined}
                onRenameColumn={canDesign(access) ? handleRenameColumn : undefined}
                onDeleteColumn={canDesign(access) ? handleDeleteColumn : undefined}
                isReordering={isReorderingColumns}
                onReorderColumns={handleReorderColumns}
              />
            </div>
          )}
        </div>
      </Main>

      {/* Object detail dialog */}
      <ObjectDetailPanel
        crmId={params.crmId}
        objectId={selectedObjectId}
        crm={crm}
        access={access}
        onClose={() => setSelectedObjectId(null)}
      />

      {canWrite(access) && (
        <CreateObjectDialog
          open={createDialogOpen}
          onOpenChange={setCreateDialogOpen}
          crmId={params.crmId}
          crm={crm}
          defaultFields={createDefaultFields}
          defaultParent={createDefaultParent}
          allowedClasses={createChildClasses || (activeView?.classes?.length ? activeView.classes : undefined)}
          onCreated={handleObjectCreated}
        />
      )}

      <KeyboardShortcutsHelp
        open={showShortcutsHelp}
        onOpenChange={setShowShortcutsHelp}
      />

      <OptionDialog
        open={addColumnDialogOpen}
        onOpenChange={setAddColumnDialogOpen}
        onAdd={handleAddColumn}
        title="Add column"
      />
    </>
  );
}
