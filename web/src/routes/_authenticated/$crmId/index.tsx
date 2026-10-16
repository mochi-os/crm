// Mochi CRM: CRM page with board and tree views
// Copyright © 2026 Mochisoft OÜ
// SPDX-License-Identifier: AGPL-3.0-only
// This file is part of Mochi, licensed under the GNU AGPL v3 with the
// Mochi Application Interface Exception - see license.txt and license-exception.md.
// The page body is EntityObjectsPage in @mochi/web, shared with the projects
// app. What stays here is the route, the loader, the wording, and the bindings
// the shared page renders through its slots.
import {
  createFileRoute,
  Link,
  redirect,
  useNavigate,
  useRouter,
} from '@tanstack/react-router'
import type { CrmDetails, CrmObject } from '@/types'
import { plural, t } from '@lingui/core/macro'
import { useLingui } from '@lingui/react/macro'
import {
  DropdownMenuItem,
  EntityLoadError,
  EntityObjectsPage,
  extractStatus,
  getErrorMessage,
  toast,
  EntityObjectDetailPanel,
  absoluteRouteUrl,
  DISALLOWED_NAME_CHARS,
} from '@mochi/web'
import { Settings, Settings2, Users } from 'lucide-react'
import crmsApi from '@/api/crms'
import { useCrmsStore } from '@/stores/crms-store'
import { ViewOptionsBar } from '@/components/view-options-bar'
import { BoardContainer } from '@/features/board/components'
import { CreateObjectDialog } from '@/features/objects/components'
import { TreeView } from '@/features/tree'

interface SearchParams {
  view?: string
}

export const Route = createFileRoute('/_authenticated/$crmId/')({
  validateSearch: (search: Record<string, unknown>): SearchParams => ({
    view: typeof search.view === 'string' ? search.view : undefined,
  }),
  loader: async ({ params }) => {
    try {
      const crmResponse = await crmsApi.get(params.crmId)
      return { crm: crmResponse.data, loaderError: null }
    } catch (error) {
      const status = extractStatus(error)
      // Redirect from the loader, not the component: a CRM-to-CRM navigation
      // re-renders the same instance rather than remounting, so a mount
      // effect never re-fires and the page is left blank.
      if (status === 403) {
        toast.error(t`You don't have access to this CRM.`)
        throw redirect({ to: '/' })
      }
      if (status === 404) {
        throw redirect({ to: '/' })
      }

      return {
        crm: null as CrmDetails | null,
        loaderError: getErrorMessage(error, t`Failed to load CRM`),
      }
    }
  },
  component: CrmPage,
})

function CrmPage() {
  const { t } = useLingui()
  const { crm, loaderError } = Route.useLoaderData() as {
    crm: CrmDetails | null
    loaderError: string | null
  }
  const params = Route.useParams()
  const search = Route.useSearch()
  const navigate = useNavigate()
  const router = useRouter()

  if (!crm) {
    return (
      <EntityLoadError
        title={t`CRM`}
        icon={<Users className='size-4 md:size-5' />}
        back={{
          label: t`Back to CRMs`,
          onFallback: () => navigate({ to: '/' }),
        }}
        message={loaderError ?? t`Failed to load CRM`}
        onRetry={() => void router.invalidate()}
      />
    )
  }

  return <CrmPageContent crm={crm} crmId={params.crmId} search={search} />
}

interface CrmPageContentProps {
  crm: CrmDetails
  crmId: string
  search: SearchParams
  initialObjectId?: string
}

export function CrmPageContent({
  crm,
  crmId,
  search,
  initialObjectId,
}: CrmPageContentProps) {
  const { t } = useLingui()
  const navigate = useNavigate()
  const router = useRouter()
  const refreshSidebar = useCrmsStore((state) => state.refresh)

  return (
    <EntityObjectsPage<CrmObject>
      design={crm}
      container={crm.crm}
      containerId={crmId}
      search={search}
      initialObjectId={initialObjectId}
      icon={Users}
      api={crmsApi}
      entity='crm'
      storagePrefix='crms'
      listKey='crms'
      backupSlug='crm'
      refreshSidebar={refreshSidebar}
      onLeave={() => void navigate({ to: '/' })}
      // An empty CRM opens on its companies view: the first thing to add is a
      // company, and the default view has nothing to show until one exists.
      emptyViewClass='company'
      labels={{
        pageActions: t`Open page actions`,
        createShort: t`New`,
        // `className.toLowerCase()` rather than a variable, so the extracted
        // message keeps the positional placeholder this app already ships.
        createAction: (className) =>
          className ? t`New ${className.toLowerCase()}` : t`New`,
        noClasses: t`Please add one or more classes to the CRM design.`,
        viewOptions: t`View options`,
        addColumn: t`Add column`,
        reorderColumns: t`Re-order columns`,
        reorderHint: t`Drag columns to re-order them`,
        cancel: t`Cancel`,
        save: t`Save`,
        boardHint: t`Double click on a column to add content`,
        dismissBoardHint: t`Dismiss board hint`,
        exportData: t`Export data`,
        loading: t`Loading...`,
        downloaded: (filename) => t`Downloaded ${filename}`,
        exportFailed: t`Failed to export data`,
        shareAction: t`Link`,
        shareTitle: t`CRM link`,
        shareFailed: t`Failed to create link`,
        moveFailed: t`Failed to move`,
        columnCreateFailed: t`Failed to add column`,
        columnRenameFailed: t`Failed to rename column`,
        columnDeleteFailed: t`Failed to delete column`,
        columnReorderFailed: t`Failed to re-order columns`,
        unsubscribe: t`Unsubscribe`,
        unsubscribeTitle: t`Unsubscribe from CRM?`,
        unsubscribeDescription: t`This will remove "${crm.crm.name}" from your sidebar and stop updates for this CRM.`,
        unsubscribing: t`Unsubscribing...`,
        unsubscribed: t`Unsubscribed`,
        unsubscribeFailed: t`Failed to unsubscribe`,
      }}
      csvExport={{
        menuAction: t`Export CSV`,
        noObjects: t`No objects to export.`,
        idColumn: t`ID`,
        classColumn: t`Class`,
        parentColumn: t`Parent`,
      }}
      // Duplicate runs the backup export and the create-from-backup import as
      // one step. A failed import removes the half-made copy.
      duplicate={{
        menuAction: t`Duplicate`,
        api: crmsApi,
        create: async (name, privacy) => {
          const response = await crmsApi.create({ name, privacy })
          const id = response.data?.fingerprint
          if (!id) throw new Error(t`Failed to duplicate CRM`)
          return id
        },
        remove: (id) => crmsApi.delete(id),
        onDuplicated: (id) => {
          void refreshSidebar()
          void navigate({ to: '/$crmId', params: { crmId: id } })
        },
        validateName: (name) => {
          if (!name.trim()) return t`CRM name is required`
          if (name.length > 1000) return t`Name must be 1000 characters or less`
          if (DISALLOWED_NAME_CHARS.test(name))
            return t`Name cannot contain < or > characters`
          return null
        },
        labels: {
          title: t`Duplicate CRM`,
          name: t`Name`,
          everything: t`Everything`,
          designOnly: t`Design only`,
          allowSearch: t`Allow anyone to search for CRM`,
          cancel: t`Cancel`,
          confirm: t`Duplicate`,
          duplicating: t`Duplicating CRM...`,
          duplicated: t`CRM duplicated`,
          failed: t`Failed to duplicate CRM`,
          defaultName: (name) => t`Duplicate of ${name}`,
          leftBehind: t`Could not remove the unfinished copy`,
        },
      }}
      designMenuItem={
        <DropdownMenuItem asChild>
          <Link to='/$crmId/design' params={{ crmId }}>
            <Settings2 className='me-2 size-4' />
            {t`Design`}
          </Link>
        </DropdownMenuItem>
      }
      settingsMenuItem={
        <DropdownMenuItem asChild>
          <Link to='/$crmId/settings' params={{ crmId }}>
            <Settings className='me-2 size-4' />
            {t`Settings`}
          </Link>
        </DropdownMenuItem>
      }
      renderViewOptionsBar={(props) => <ViewOptionsBar crm={crm} {...props} />}
      renderBoard={(props) => <BoardContainer crm={crm} {...props} />}
      renderTree={(props) => <TreeView crm={crm} crmId={crmId} {...props} />}
      renderCreateDialog={(props) => (
        <CreateObjectDialog crmId={crmId} crm={crm} {...props} />
      )}
      renderDetailPanel={({ objectId, onCopy, onClose }) => (
        <EntityObjectDetailPanel
          containerId={crmId}
          objectId={objectId}
          design={crm}
          access={crm.crm.access}
          api={crmsApi}
          itemUrl={(objectId) =>
            absoluteRouteUrl(router, {
              to: '/$crmId/$objectId',
              params: { crmId, objectId },
            })
          }
          labels={{
            copyLink: t`Copy link`,
            // The server deletes everything under an item with it.
            deleteWithChildren: (title, count) =>
              t`Are you sure you want to delete "${title}" and the ${plural(count, { one: '# item', other: '# items' })} under it? This action cannot be undone.`,
          }}
          onCopy={onCopy}
          onClose={onClose}
        />
      )}
    />
  )
}
