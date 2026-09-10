// Mochi CRMs: Design editor main component
// Copyright © 2026 Mochisoft OÜ
// SPDX-License-Identifier: AGPL-3.0-only
// This file is part of Mochi, licensed under the GNU AGPL v3 with the
// Mochi Application Interface Exception - see license.txt and license-exception.md.
import { useState, useMemo } from 'react'
import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query'
import type { CrmDetails, CrmField, CrmView, FieldOption } from '@/types'
import { Trans, useLingui } from '@lingui/react/macro'
import {
  Button,
  Label,
  toast,
  getErrorMessage,
  Tooltip,
  TooltipContent,
  TooltipTrigger,
} from '@mochi/web'
import { Blocks, GripVertical, Plus } from 'lucide-react'
import crmsApi from '@/api/crms'
import { AddFieldDialog } from './add-dialogs'
import { DesignPreview } from './design-preview'
import {
  ViewSheet,
  ClassSheet,
  EditFieldDialog,
  type PendingField,
} from './edit-dialogs'
import { OptionDialog } from './option-dialog'

interface DesignEditorProps {
  crmId: string
  crm: CrmDetails
}

export function DesignEditor({ crmId, crm }: DesignEditorProps) {
  const { t } = useLingui()
  const queryClient = useQueryClient()

  // Fetch objects for preview
  const { data: objectsData } = useQuery({
    queryKey: ['objects', crmId],
    queryFn: async () => {
      const response = await crmsApi.listObjects(crmId)
      return response.data.objects
    },
  })
  const objects = objectsData || []

  // Selection state
  const [selectedClassId, setSelectedClassId] = useState<string | null>(
    crm.classes[0]?.id || null
  )

  // Add dialog state
  const [addClassOpen, setAddClassOpen] = useState(false)
  const [addFieldOpen, setAddFieldOpen] = useState(false)
  const [addOptionOpen, setAddOptionOpen] = useState(false)
  const [addViewOpen, setAddViewOpen] = useState(false)

  // Edit dialog state
  const [editViewOpen, setEditViewOpen] = useState(false)
  const [editClassOpen, setEditClassOpen] = useState(false)
  const [editFieldOpen, setEditFieldOpen] = useState(false)
  const [editOptionOpen, setEditOptionOpen] = useState(false)
  const [editingView, setEditingView] = useState<CrmView | null>(null)
  const [editingField, setEditingField] = useState<CrmField | null>(null)
  const [editingOption, setEditingOption] = useState<FieldOption | null>(null)

  // View drag state
  const [draggedViewId, setDraggedViewId] = useState<string | null>(null)
  const [viewDropIndicator, setViewDropIndicator] = useState<{
    viewId: string
    position: 'before' | 'after'
  } | null>(null)

  // Get current selections
  const selectedClass = crm.classes.find((c) => c.id === selectedClassId)
  const selectedFields = selectedClassId
    ? crm.fields[selectedClassId] || []
    : []
  const hierarchy = selectedClassId ? crm.hierarchy[selectedClassId] || [] : []

  // Get all fields across all classes for view editing
  const allFields = useMemo(() => {
    const fieldsMap = new Map<string, CrmField>()
    for (const classId of Object.keys(crm.fields)) {
      for (const field of crm.fields[classId]) {
        if (!fieldsMap.has(field.id)) {
          fieldsMap.set(field.id, field)
        }
      }
    }
    return Array.from(fieldsMap.values())
  }, [crm.fields])

  // Keep editingField in sync with refetched crm data
  const resolvedEditingField = useMemo(() => {
    if (!editingField || !selectedClassId) return editingField
    const fields = crm.fields[selectedClassId] || []
    return fields.find((f) => f.id === editingField.id) || editingField
  }, [editingField, selectedClassId, crm.fields])

  // Get options for editing field
  const editingFieldOptions =
    selectedClassId && resolvedEditingField
      ? crm.options[selectedClassId]?.[resolvedEditingField.id] || []
      : []

  // Invalidate crm data
  const invalidateCrm = () => {
    queryClient.invalidateQueries({ queryKey: ['crm', crmId] })
  }

  // Class mutations
  const createClassMutation = useMutation({
    mutationFn: ({ name }: { name: string }) =>
      crmsApi.createClass(crmId, { name }),
    onSuccess: (data) => {
      invalidateCrm()
      setSelectedClassId(data.data.id)
    },
    onError: (error) => {
      toast.error(getErrorMessage(error, t`Failed to create class`))
    },
  })

  const updateClassMutation = useMutation({
    mutationFn: ({
      classId,
      name,
      title,
    }: {
      classId: string
      name: string
      title?: string
    }) => crmsApi.updateClass(crmId, classId, { name, title }),
    onSuccess: invalidateCrm,
    onError: (error) => {
      toast.error(getErrorMessage(error, t`Failed to update class`))
    },
  })

  const deleteClassMutation = useMutation({
    mutationFn: (classId: string) => crmsApi.deleteClass(crmId, classId),
    onSuccess: (_result, classId) => {
      invalidateCrm()
      setSelectedClassId(crm.classes.find((c) => c.id !== classId)?.id || null)
      setEditClassOpen(false)
    },
    onError: (error) => {
      toast.error(getErrorMessage(error, t`Failed to delete class`))
    },
  })

  // Hierarchy mutation
  const setHierarchyMutation = useMutation({
    mutationFn: ({
      classId,
      parents,
    }: {
      classId: string
      parents: string[]
    }) => crmsApi.setHierarchy(crmId, classId, parents),
    onSuccess: invalidateCrm,
    onError: (error) => {
      toast.error(getErrorMessage(error, t`Failed to update hierarchy`))
    },
  })

  // Field mutations
  const createFieldMutation = useMutation({
    mutationFn: ({
      classId,
      name,
      fieldtype,
      rows,
    }: {
      classId: string
      name: string
      fieldtype: string
      rows?: number
    }) =>
      crmsApi.createField(crmId, classId, {
        name,
        fieldtype,
        rows: rows?.toString(),
      }),
    onSuccess: invalidateCrm,
    onError: (error) => {
      toast.error(getErrorMessage(error, t`Failed to create field`))
    },
  })

  const updateFieldMutation = useMutation({
    mutationFn: ({
      classId,
      fieldId,
      updates,
    }: {
      classId: string
      fieldId: string
      updates: Partial<CrmField>
    }) =>
      crmsApi.updateField(crmId, classId, fieldId, {
        id: updates.id,
        name: updates.name,
        flags: updates.flags,
        rows: updates.rows?.toString(),
        pattern: updates.pattern,
        minlength: updates.minlength?.toString(),
        maxlength: updates.maxlength?.toString(),
      }),
    onSuccess: (_, variables) => {
      // If the field was renamed, update editingField to point to the new ID
      if (variables.updates.id && variables.updates.id !== variables.fieldId) {
        setEditingField((prev) =>
          prev ? { ...prev, id: variables.updates.id! } : prev
        )
      }
      invalidateCrm()
    },
    onError: (error) => {
      toast.error(getErrorMessage(error, t`Failed to update field`))
    },
  })

  const deleteFieldMutation = useMutation({
    mutationFn: ({ classId, fieldId }: { classId: string; fieldId: string }) =>
      crmsApi.deleteField(crmId, classId, fieldId),
    onSuccess: () => {
      invalidateCrm()
      setEditFieldOpen(false)
    },
    onError: (error) => {
      toast.error(getErrorMessage(error, t`Failed to delete field`))
    },
  })

  const reorderFieldsMutation = useMutation({
    mutationFn: ({ classId, order }: { classId: string; order: string[] }) =>
      crmsApi.reorderFields(crmId, classId, order),
    onSuccess: invalidateCrm,
    onError: (error) => {
      toast.error(getErrorMessage(error, t`Failed to reorder fields`))
    },
  })

  // Option mutations
  const createOptionMutation = useMutation({
    mutationFn: ({
      classId,
      fieldId,
      name,
      colour,
    }: {
      classId: string
      fieldId: string
      name: string
      colour: string
    }) => crmsApi.createOption(crmId, classId, fieldId, { name, colour }),
    onSuccess: invalidateCrm,
    onError: (error) => {
      toast.error(getErrorMessage(error, t`Failed to create option`))
    },
  })

  const updateOptionMutation = useMutation({
    mutationFn: ({
      classId,
      fieldId,
      optionId,
      updates,
    }: {
      classId: string
      fieldId: string
      optionId: string
      updates: { name?: string; colour?: string }
    }) => crmsApi.updateOption(crmId, classId, fieldId, optionId, updates),
    onSuccess: invalidateCrm,
    onError: (error) => {
      toast.error(getErrorMessage(error, t`Failed to update option`))
    },
  })

  const deleteOptionMutation = useMutation({
    mutationFn: ({
      classId,
      fieldId,
      optionId,
    }: {
      classId: string
      fieldId: string
      optionId: string
    }) => crmsApi.deleteOption(crmId, classId, fieldId, optionId),
    onSuccess: () => {
      invalidateCrm()
      setEditOptionOpen(false)
    },
    onError: (error) => {
      toast.error(getErrorMessage(error, t`Failed to delete option`))
    },
  })

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
      name: string
      viewtype: string
      columns?: string
      rows?: string
      border?: string
      fields?: string
      sort?: string
      direction?: 'asc' | 'desc'
      classes?: string
    }) =>
      crmsApi.createView(crmId, {
        name,
        viewtype: viewtype as 'board' | 'list',
        fields: fields || allFields.map((f) => f.id).join(','),
        columns,
        rows,
        border,
        sort,
        direction,
        classes,
      }),
    onSuccess: invalidateCrm,
    onError: (error) => {
      toast.error(getErrorMessage(error, t`Failed to create view`))
    },
  })

  const updateViewMutation = useMutation({
    mutationFn: ({
      viewId,
      updates,
      types,
    }: {
      viewId: string
      updates?: Partial<CrmView>
      types?: string[]
    }) => {
      // Only what changed: view/update applies the fields it is sent and
      // leaves the rest, so a full snapshot taken from the last fetched
      // design raced a still-refetching earlier edit and reverted it.
      const payload: Record<string, string> = {}
      if (updates) {
        if (updates.name !== undefined) payload.name = updates.name
        if (updates.viewtype !== undefined) payload.viewtype = updates.viewtype
        if (updates.filter !== undefined) payload.filter = updates.filter
        if (updates.columns !== undefined) payload.columns = updates.columns
        if (updates.rows !== undefined) payload.rows = updates.rows
        if (updates.border !== undefined) payload.border = updates.border
        if (updates.fields !== undefined) payload.fields = updates.fields
        if (updates.sort !== undefined) payload.sort = updates.sort
        if (updates.direction !== undefined)
          payload.direction = updates.direction
      }
      if (types !== undefined)
        payload.classes =
          types.length === crm.classes.length ? '' : types.join(',')
      return crmsApi.updateView(crmId, viewId, payload)
    },
    onSuccess: invalidateCrm,
    onError: (error) => {
      toast.error(getErrorMessage(error, t`Failed to update view`))
    },
  })

  const deleteViewMutation = useMutation({
    mutationFn: (viewId: string) => crmsApi.deleteView(crmId, viewId),
    onSuccess: () => {
      invalidateCrm()
      setEditViewOpen(false)
    },
    onError: (error) => {
      toast.error(getErrorMessage(error, t`Failed to delete view`))
    },
  })

  const reorderViewsMutation = useMutation({
    mutationFn: (order: string[]) => crmsApi.reorderViews(crmId, order),
    onSuccess: invalidateCrm,
    onError: (error) => {
      toast.error(getErrorMessage(error, t`Failed to reorder views`))
    },
  })

  // Handlers
  const handleEditView = (view: CrmView) => {
    setEditingView(view)
    setEditViewOpen(true)
  }

  const handleEditField = (field: CrmField) => {
    setEditingField(field)
    setEditFieldOpen(true)
  }

  const handleEditOption = (option: FieldOption) => {
    setEditingOption(option)
    setEditOptionOpen(true)
  }

  // Create class with chained API calls
  const handleCreateClass = async (
    name: string,
    parents: string[],
    pendingFields: PendingField[]
  ) => {
    const result = await createClassMutation.mutateAsync({ name })
    const classId = result.data?.id
    if (!classId) return

    try {
      if (parents.length > 0) {
        await setHierarchyMutation.mutateAsync({ classId, parents })
      }

      // Create each non-title field (title is auto-created by the backend)
      for (const field of pendingFields) {
        if (field.id === 'title') continue
        const fieldResult = await createFieldMutation.mutateAsync({
          classId,
          name: field.name,
          fieldtype: field.fieldtype,
          rows: field.rows,
        })
        // Create options for enumerated fields
        if (
          field.fieldtype === 'enumerated' &&
          field.options &&
          fieldResult.data
        ) {
          for (const opt of field.options) {
            await createOptionMutation.mutateAsync({
              classId,
              fieldId: fieldResult.data.id,
              name: opt.name,
              colour: opt.colour,
            })
          }
        }
      }
    } catch (error) {
      // The class already exists on the server and the sidebar shows it, so a
      // retry from the still-open sheet would create a second one with the
      // same name. Take the half-built class back out so the retry starts
      // clean; the failed step's onError has already said what went wrong.
      await crmsApi.deleteClass(crmId, classId).catch(() => {})
      invalidateCrm()
      throw error
    }
  }

  // View drag handlers
  const handleViewDragStart = (e: React.DragEvent, viewId: string) => {
    setDraggedViewId(viewId)
    e.dataTransfer.effectAllowed = 'move'
    e.dataTransfer.setData('text/plain', viewId)
  }

  const handleViewDragEnd = () => {
    setDraggedViewId(null)
    setViewDropIndicator(null)
  }

  const handleViewDragOver = (e: React.DragEvent, viewId: string) => {
    e.preventDefault()
    if (viewId === draggedViewId) return
    const rect = e.currentTarget.getBoundingClientRect()
    const midY = rect.top + rect.height / 2
    const position = e.clientY < midY ? 'before' : 'after'
    setViewDropIndicator({ viewId, position })
  }

  const handleViewDragLeave = () => {
    setViewDropIndicator(null)
  }

  const handleViewDrop = (e: React.DragEvent, targetViewId: string) => {
    e.preventDefault()
    if (!draggedViewId || draggedViewId === targetViewId) return

    const currentOrder = crm.views.map((v) => v.id)
    const draggedIndex = currentOrder.indexOf(draggedViewId)
    const targetIndex = currentOrder.indexOf(targetViewId)
    if (draggedIndex === -1 || targetIndex === -1) return

    const newOrder = [...currentOrder]
    newOrder.splice(draggedIndex, 1)
    const insertIndex =
      viewDropIndicator?.position === 'after'
        ? currentOrder.indexOf(targetViewId) -
          (draggedIndex < targetIndex ? 1 : 0) +
          1
        : currentOrder.indexOf(targetViewId) -
          (draggedIndex < targetIndex ? 1 : 0)
    newOrder.splice(insertIndex, 0, draggedViewId)

    reorderViewsMutation.mutate(newOrder)
    setDraggedViewId(null)
    setViewDropIndicator(null)
  }

  return (
    <div className='flex h-full'>
      {/* Editor panel (left) */}
      <div className='flex w-80 flex-col overflow-hidden border-e'>
        <div className='flex-1 space-y-6 overflow-auto p-4'>
          {/* Views Section */}
          <section>
            <div className='mb-2 flex items-center justify-between'>
              <Label className='text-sm font-medium'>
                <Trans>Views</Trans>
              </Label>
              <Tooltip>
                <TooltipTrigger asChild>
                  <Button
                    variant='ghost'
                    size='sm'
                    onClick={() => setAddViewOpen(true)}
                    aria-label={t`Add view`}
                  >
                    <Plus className='size-4' />
                  </Button>
                </TooltipTrigger>
                <TooltipContent>{t`Add view`}</TooltipContent>
              </Tooltip>
            </div>
            <div className='space-y-1'>
              {crm.views.map((view) => (
                <div key={view.id}>
                  {viewDropIndicator?.viewId === view.id &&
                    viewDropIndicator.position === 'before' && (
                      <div className='bg-primary mx-3 h-0.5 rounded-full' />
                    )}
                  <div
                    draggable
                    onDragStart={(e) => handleViewDragStart(e, view.id)}
                    onDragEnd={handleViewDragEnd}
                    onDragOver={(e) => handleViewDragOver(e, view.id)}
                    onDragLeave={handleViewDragLeave}
                    onDrop={(e) => handleViewDrop(e, view.id)}
                    className={`hover:bg-hover flex cursor-grab items-center gap-2 rounded-md px-3 py-2 text-sm transition-colors ${
                      draggedViewId === view.id ? 'opacity-50' : ''
                    }`}
                  >
                    <GripVertical className='text-muted-foreground size-4 shrink-0' />
                    <button
                      type='button'
                      onClick={() => handleEditView(view)}
                      className='flex-1 text-start'
                    >
                      <span className='font-medium'>{view.name}</span>
                    </button>
                  </div>
                  {viewDropIndicator?.viewId === view.id &&
                    viewDropIndicator.position === 'after' && (
                      <div className='bg-primary mx-3 h-0.5 rounded-full' />
                    )}
                </div>
              ))}
            </div>
          </section>

          <hr className='border-border' />

          {/* Classes Section */}
          <section>
            <div className='mb-2 flex items-center justify-between'>
              <Label className='text-sm font-medium'>
                <Trans>Classes</Trans>
              </Label>
              <Tooltip>
                <TooltipTrigger asChild>
                  <Button
                    variant='ghost'
                    size='sm'
                    onClick={() => setAddClassOpen(true)}
                    aria-label={t`Add class`}
                  >
                    <Plus className='size-4' />
                  </Button>
                </TooltipTrigger>
                <TooltipContent>{t`Add class`}</TooltipContent>
              </Tooltip>
            </div>
            <div className='space-y-1'>
              {crm.classes.map((cls) => (
                <button
                  key={cls.id}
                  onClick={() => {
                    setSelectedClassId(cls.id)
                    setEditClassOpen(true)
                  }}
                  className='hover:bg-hover flex w-full items-center gap-2 rounded-md px-3 py-2 text-start text-sm transition-colors'
                >
                  <Blocks className='text-muted-foreground size-4 shrink-0' />
                  {cls.name}
                </button>
              ))}
            </div>
          </section>
        </div>
      </div>

      {/* Preview panel (right) */}
      <div className='flex-1 overflow-hidden'>
        <DesignPreview
          crm={crm}
          crmId={crmId}
          objects={objects}
          selectedClassId={selectedClassId}
        />
      </div>

      {/* Add view (create mode) */}
      <ViewSheet
        open={addViewOpen}
        onOpenChange={setAddViewOpen}
        mode='create'
        fields={allFields}
        classes={crm.classes}
        onCreate={async (
          name,
          viewtype,
          columns,
          rows,
          selectedFields,
          sort,
          direction,
          selectedClasses,
          border
        ) => {
          await createViewMutation.mutateAsync({
            name,
            viewtype,
            columns: columns || undefined,
            rows: rows || undefined,
            border: border || undefined,
            fields: selectedFields.join(','),
            sort: sort || undefined,
            direction: direction as 'asc' | 'desc',
            classes:
              selectedClasses.length === crm.classes.length
                ? ''
                : selectedClasses.join(','),
          })
        }}
      />

      {/* Add class (create mode) */}
      <ClassSheet
        open={addClassOpen}
        onOpenChange={setAddClassOpen}
        mode='create'
        classes={crm.classes}
        onCreate={handleCreateClass}
      />

      <AddFieldDialog
        open={addFieldOpen}
        onOpenChange={setAddFieldOpen}
        onAdd={async (name, fieldtype, rows, options) => {
          // The mutations' onError toasts, and a rejection reaches the dialog,
          // which stays open; a second toast here doubled every failure.
          if (selectedClassId) {
            const result = await createFieldMutation.mutateAsync({
              classId: selectedClassId,
              name,
              fieldtype,
              rows,
            })
            // Create options for enumerated fields
            if (fieldtype === 'enumerated' && options && result.data) {
              for (const opt of options) {
                await createOptionMutation.mutateAsync({
                  classId: selectedClassId,
                  fieldId: result.data.id,
                  name: opt.name,
                  colour: opt.colour,
                })
              }
            }
          }
        }}
      />

      <OptionDialog
        open={addOptionOpen}
        onOpenChange={setAddOptionOpen}
        onAdd={async (name, colour) => {
          if (selectedClassId && resolvedEditingField) {
            await createOptionMutation.mutateAsync({
              classId: selectedClassId,
              fieldId: resolvedEditingField.id,
              name,
              colour,
            })
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
            updateViewMutation.mutate({ viewId: editingView.id, updates })
          }
        }}
        onUpdateClasses={(classes) => {
          if (editingView) {
            updateViewMutation.mutate({
              viewId: editingView.id,
              types: classes,
            })
          }
        }}
        onDelete={() => {
          if (editingView) {
            deleteViewMutation.mutate(editingView.id)
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
        onUpdate={(name, title) => {
          if (selectedClassId) {
            updateClassMutation.mutate({
              classId: selectedClassId,
              name,
              title,
            })
          }
        }}
        onUpdateHierarchy={(parents) => {
          if (selectedClassId) {
            setHierarchyMutation.mutate({ classId: selectedClassId, parents })
          }
        }}
        onDelete={() => {
          if (selectedClassId) {
            deleteClassMutation.mutate(selectedClassId)
          }
        }}
        onAddField={() => setAddFieldOpen(true)}
        onEditField={handleEditField}
        onReorderFields={(order) => {
          if (selectedClassId) {
            reorderFieldsMutation.mutate({ classId: selectedClassId, order })
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
              return updateFieldMutation
                .mutateAsync({
                  classId: selectedClassId,
                  fieldId: resolvedEditingField.id,
                  updates,
                })
                .then(() => {})
            }
            updateFieldMutation.mutate({
              classId: selectedClassId,
              fieldId: resolvedEditingField.id,
              updates,
            })
          }
        }}
        onDelete={() => {
          if (selectedClassId && resolvedEditingField) {
            deleteFieldMutation.mutate({
              classId: selectedClassId,
              fieldId: resolvedEditingField.id,
            })
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
            })
          }
        }}
      />

      <OptionDialog
        open={editOptionOpen}
        onOpenChange={setEditOptionOpen}
        option={editingOption}
        onUpdate={(updates) => {
          if (selectedClassId && resolvedEditingField && editingOption) {
            updateOptionMutation.mutate({
              classId: selectedClassId,
              fieldId: resolvedEditingField.id,
              optionId: editingOption.id,
              updates,
            })
          }
        }}
        onDelete={() => {
          if (selectedClassId && resolvedEditingField && editingOption) {
            deleteOptionMutation.mutate({
              classId: selectedClassId,
              fieldId: resolvedEditingField.id,
              optionId: editingOption.id,
            })
          }
        }}
      />
    </div>
  )
}
