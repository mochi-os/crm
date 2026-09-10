// Copyright © 2026 Mochisoft OÜ
// SPDX-License-Identifier: AGPL-3.0-only
// This file is part of Mochi, licensed under the GNU AGPL v3 with the
// Mochi Application Interface Exception - see license.txt and license-exception.md.
import { useCallback, useEffect, useMemo, useRef, useState } from 'react'
import { useNavigate } from '@tanstack/react-router'
import { plural } from '@lingui/core/macro'
import { Trans, useLingui } from '@lingui/react/macro'
import {
  Button,
  ResponsiveDialog,
  ResponsiveDialogContent,
  ResponsiveDialogFooter,
  ResponsiveDialogHeader,
  ResponsiveDialogDescription,
  ResponsiveDialogTitle,
  ResponsiveDialogTrigger,
  Input,
  Label,
  Switch,
  toast,
  toastAction,
  getErrorMessage,
  Attachment,
  AttachmentMedia,
  AttachmentContent,
  AttachmentTitle,
  AttachmentAction,
  Tooltip,
  TooltipContent,
  TooltipTrigger,
  useUploadProgress,
  UploadProgress,
  DISALLOWED_NAME_CHARS,
} from '@mochi/web'
import { Loader2, Plus, Upload, Users, X } from 'lucide-react'
import crmsApi from '@/api/crms'
import { useCrmsStore } from '@/stores/crms-store'

interface CreateCrmDialogProps {
  open?: boolean
  onOpenChange?: (open: boolean) => void
  hideTrigger?: boolean
}

export function CreateCrmDialog({
  open,
  onOpenChange,
  hideTrigger,
}: CreateCrmDialogProps) {
  const { t } = useLingui()
  const [isPending, setIsPending] = useState(false)
  const [name, setName] = useState('')
  const [allowSearch, setAllowSearch] = useState(true)
  const [importData, setImportData] = useState<Record<string, unknown> | null>(
    null
  )
  const [importFile, setImportFile] = useState<File | null>(null)
  const [importArchive, setImportArchive] = useState(false)
  const [importFileName, setImportFileName] = useState('')
  const fileInputRef = useRef<HTMLInputElement>(null)
  const navigate = useNavigate()
  const refreshCrms = useCrmsStore((state) => state.refresh)
  const { progress: importProgress, upload } = useUploadProgress()

  // The submit guards read pairs of these four, so clearing a subset leaves a
  // removed file still importable - and the archive branch rolls the new CRM
  // back on failure, deleting one the user never meant to import into.
  const clearImport = useCallback(() => {
    setImportData(null)
    setImportFile(null)
    setImportArchive(false)
    setImportFileName('')
  }, [])

  // Reset state when dialog closes
  useEffect(() => {
    if (!open) {
      setName('')
      setAllowSearch(true)
      clearImport()
    }
  }, [open, clearImport])

  const handleSubmit = async (e: React.FormEvent) => {
    e.preventDefault()

    if (!name.trim()) {
      toast.error(t`Name is required`)
      return
    }
    // The rule the settings page and the server apply.
    if (name.length > 1000) {
      toast.error(t`Name must be 1000 characters or less`)
      return
    }
    if (DISALLOWED_NAME_CHARS.test(name)) {
      toast.error(t`Name cannot contain < or > characters`)
      return
    }

    setIsPending(true)
    try {
      const response = await toastAction(
        crmsApi.create({
          name: name.trim(),
          privacy: allowSearch ? 'public' : 'private',
        }),
        {
          loading: t`Creating CRM...`,
          success: t`CRM created`,
          error: (e) => getErrorMessage(e, t`Failed to create CRM`),
        }
      )

      const fingerprint = response.data?.fingerprint

      if (fingerprint && importArchive && importFile) {
        // The archive restores design and data together, so there is no
        // separate design pass and nothing to decide from client-side parsing.
        try {
          await toastAction(
            upload((onProgress) =>
              crmsApi.importData(fingerprint, importFile, onProgress, true)
            ),
            {
              loading: t`Importing data...`,
              success: (imported) =>
                t`Data imported (${plural(imported.data?.objects ?? 0, { one: '# object', other: '# objects' })}, ${plural(imported.data?.comments ?? 0, { one: '# comment', other: '# comments' })}, ${plural(imported.data?.links ?? 0, { one: '# link', other: '# links' })})`,
              error: (e) => getErrorMessage(e, t`Failed to import data`),
            }
          )
        } catch (e) {
          await crmsApi.delete(fingerprint).catch(() => {})
          throw e
        }
      } else if (fingerprint && importData && importFile) {
        // A design-only backup (an empty CRM) has nothing for data/import,
        // which rejects an empty payload — skip the call rather than fail
        // and roll the new CRM back.
        const importHasData =
          (Array.isArray(importData.objects) &&
            importData.objects.length > 0) ||
          (Array.isArray(importData.links) && importData.links.length > 0)
        if (importDesign || importHasData) {
          try {
            await toastAction(
              (async () => {
                if (importDesign) {
                  await crmsApi.importDesign(fingerprint, importDesign)
                }
                return importHasData
                  ? upload((onProgress) =>
                      crmsApi.importData(fingerprint, importFile, onProgress)
                    )
                  : null
              })(),
              {
                loading: t`Importing data...`,
                success: (imported) =>
                  imported
                    ? t`Data imported (${plural(imported.data?.objects ?? 0, { one: '# object', other: '# objects' })}, ${plural(imported.data?.comments ?? 0, { one: '# comment', other: '# comments' })}, ${plural(imported.data?.links ?? 0, { one: '# link', other: '# links' })})`
                    : t`Design imported`,
                error: (e) => getErrorMessage(e, t`Failed to import data`),
              }
            )
          } catch (e) {
            await crmsApi.delete(fingerprint).catch(() => {})
            throw e
          }
        }
      }

      await refreshCrms()

      onOpenChange?.(false)

      if (fingerprint) {
        void navigate({
          to: '/$crmId',
          params: { crmId: fingerprint },
        })
      } else {
        void navigate({ to: '/' })
      }
    } catch {
      // toast already shown
    } finally {
      setIsPending(false)
    }
  }

  // Design snapshot embedded in the backup (newer exports). When present, it
  // replaces the new CRM's default design via design/import before the data
  // import — restoring from the default design breaks on any customized or
  // drifted source design (added classes, extra fields, changed options).
  const importDesign = useMemo(() => {
    if (!importData) return null
    const design = importData.design
    if (design && typeof design === 'object' && !Array.isArray(design)) {
      return design as Record<string, unknown>
    }
    // A design export (Design page, Export) is the design itself with no
    // wrapper: classes at the top level and nothing to import as data.
    return Array.isArray(importData.classes) ? importData : null
  }, [importData])

  const handleFileChange = (e: React.ChangeEvent<HTMLInputElement>) => {
    const file = e.target.files?.[0]
    if (!file) return

    // A container backup keeps its attachments as archive entries rather than
    // base64 in JSON, so there is nothing here to parse: the server reads the
    // manifest out of the archive and applies the design it carries.
    if (file.name.toLowerCase().endsWith('.zip')) {
      setImportArchive(true)
      setImportData(null)
      setImportFile(file)
      setImportFileName(file.name)
      return
    }
    setImportArchive(false)

    const reader = new FileReader()
    reader.onload = () => {
      let data: unknown
      try {
        data = JSON.parse(reader.result as string)
      } catch {
        toast.error(t`Invalid JSON file`)
        clearImport()
        return
      }
      // Anything else parsed but carried nothing the import could act on, so
      // the CRM was created from the default template with no word of it.
      const record =
        data && typeof data === 'object' && !Array.isArray(data)
          ? (data as Record<string, unknown>)
          : null
      const design = record?.design
      const usable =
        record !== null &&
        ((design !== undefined &&
          design !== null &&
          typeof design === 'object' &&
          !Array.isArray(design)) ||
          Array.isArray(record.classes) ||
          Array.isArray(record.objects) ||
          Array.isArray(record.links))
      if (!usable) {
        toast.error(t`This file is not a CRM backup`)
        clearImport()
        return
      }
      setImportData(record)
      setImportFile(file)
      setImportFileName(file.name)
      // Format 2 backups carry the source crm's metadata — prefill an
      // untouched name field so recreating keeps the original name.
      const metadata = record.crm
      if (
        metadata &&
        typeof metadata === 'object' &&
        !Array.isArray(metadata)
      ) {
        const m = metadata as Record<string, unknown>
        if (typeof m.name === 'string' && m.name && !name.trim())
          setName(m.name)
      }
    }
    reader.onerror = () => {
      toast.error(t`Failed to read file`)
      clearImport()
    }
    reader.readAsText(file)
    e.target.value = ''
  }

  return (
    <ResponsiveDialog open={open} onOpenChange={onOpenChange}>
      {!hideTrigger && (
        <ResponsiveDialogTrigger asChild>
          <Button>
            <Plus className='me-2 size-4' />
            <Trans>Create CRM</Trans>
          </Button>
        </ResponsiveDialogTrigger>
      )}
      <ResponsiveDialogContent className='sm:max-w-md'>
        <ResponsiveDialogHeader>
          <ResponsiveDialogTitle className='flex items-center gap-2'>
            <div className='bg-primary/10 text-primary flex size-8 items-center justify-center rounded-lg'>
              <Users className='size-4' />
            </div>
            <Trans>Create CRM</Trans>
          </ResponsiveDialogTitle>
          <ResponsiveDialogDescription className='sr-only'>
            <Trans>Create a new CRM</Trans>
          </ResponsiveDialogDescription>
        </ResponsiveDialogHeader>

        <form onSubmit={handleSubmit}>
          <div className='mt-4 space-y-4'>
            <div className='space-y-2'>
              <Label htmlFor='name'>
                <Trans>Name</Trans>
              </Label>
              <Input
                id='name'
                value={name}
                onChange={(e) => setName(e.target.value)}
                placeholder={t`Sales CRM`}
                autoFocus
              />
            </div>

            <div className='flex items-center justify-between rounded-lg border px-4 py-3'>
              <Label
                htmlFor='allow-search'
                className='cursor-pointer text-sm font-medium'
              >
                <Trans>Allow anyone to search for CRM</Trans>
              </Label>
              <Switch
                id='allow-search'
                checked={allowSearch}
                onCheckedChange={setAllowSearch}
              />
            </div>

            <div className='space-y-2'>
              <Label>
                <Trans>Import from backup (optional)</Trans>
              </Label>
              <input
                ref={fileInputRef}
                type='file'
                accept='.zip,.json'
                onChange={handleFileChange}
                className='hidden'
              />
              <div className='flex gap-2'>
                <Button
                  type='button'
                  variant='outline'
                  className='flex-1'
                  onClick={() => fileInputRef.current?.click()}
                >
                  <Upload className='me-1.5 size-4' />
                  <Trans>Upload backup file</Trans>
                </Button>
              </div>
              {importFileName && (
                <div className='mt-2'>
                  <Attachment orientation='horizontal'>
                    <AttachmentMedia>
                      <Upload className='size-4' />
                    </AttachmentMedia>
                    <AttachmentContent>
                      <AttachmentTitle>{importFileName}</AttachmentTitle>
                    </AttachmentContent>
                    <Tooltip>
                      <TooltipTrigger asChild>
                        <AttachmentAction
                          variant='ghost'
                          onClick={() => {
                            setImportData(null)
                            setImportFile(null)
                            setImportArchive(false)
                            setImportFileName('')
                            if (fileInputRef.current) {
                              fileInputRef.current.value = ''
                            }
                          }}
                        >
                          <X className='size-4' />
                        </AttachmentAction>
                      </TooltipTrigger>
                      <TooltipContent>
                        <Trans>Remove</Trans>
                      </TooltipContent>
                    </Tooltip>
                  </Attachment>
                </div>
              )}
            </div>
          </div>

          <UploadProgress progress={importProgress} className='mt-4' />
          <ResponsiveDialogFooter className='mt-6'>
            <Button
              type='button'
              variant='outline'
              onClick={() => onOpenChange?.(false)}
            >
              <Trans>Cancel</Trans>
            </Button>
            <Button type='submit' disabled={isPending}>
              {isPending ? (
                <Loader2 className='me-2 size-4 animate-spin' />
              ) : (
                <Plus className='me-2 size-4' />
              )}
              <Trans>Create CRM</Trans>
            </Button>
          </ResponsiveDialogFooter>
        </form>
      </ResponsiveDialogContent>
    </ResponsiveDialog>
  )
}
