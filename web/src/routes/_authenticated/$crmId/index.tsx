// Mochi CRM: CRM page with board and tree views
// Copyright © 2026 Mochisoft OÜ
// SPDX-License-Identifier: AGPL-3.0-only
// This file is part of Mochi, licensed under the GNU AGPL v3 with the
// Mochi Application Interface Exception - see license.txt and license-exception.md.
// The page body is CrmPageContent in features/crms/pages/crm-page.tsx,
// shared with the item route. It lives outside the routes folder so
// TanStack can load it on demand: a route file another file imports stays
// in the first load whole. Nothing but the route tree imports a route file.
import {
  createFileRoute,
  redirect,
  useNavigate,
  useRouter,
} from '@tanstack/react-router'
import type { CrmDetails } from '@/types'
import { t } from '@lingui/core/macro'
import { useLingui } from '@lingui/react/macro'
import {
  EntityLoadError,
  extractStatus,
  getErrorMessage,
  toast,
  entityObjectsQuery,
  entityPeopleQuery,
} from '@mochi/web'
import { Users } from 'lucide-react'
import crmsApi from '@/api/crms'
import { CrmPageContent } from '@/features/crms/pages'

interface SearchParams {
  view?: string
}

export const Route = createFileRoute('/_authenticated/$crmId/')({
  validateSearch: (search: Record<string, unknown>): SearchParams => ({
    view: typeof search.view === 'string' ? search.view : undefined,
  }),
  loader: async ({ params, context }) => {
    // The items and people need only the address, so they start beside the
    // details rather than after them; the page's queries join them.
    void context.queryClient.prefetchQuery(
      entityObjectsQuery(crmsApi.listObjects, params.crmId)
    )
    void context.queryClient.prefetchQuery(
      entityPeopleQuery(crmsApi.listPeople, params.crmId)
    )
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
