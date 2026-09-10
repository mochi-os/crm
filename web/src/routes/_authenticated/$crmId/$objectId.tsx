// Mochi CRM: Object deep-link route
// Copyright © 2026 Mochisoft OÜ
// SPDX-License-Identifier: AGPL-3.0-only
// This file is part of Mochi, licensed under the GNU AGPL v3 with the
// Mochi Application Interface Exception - see license.txt and license-exception.md.
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
} from '@mochi/web'
import { Users } from 'lucide-react'
import crmsApi from '@/api/crms'
import { CrmPageContent } from './index'

interface SearchParams {
  view?: string
}

export const Route = createFileRoute('/_authenticated/$crmId/$objectId')({
  validateSearch: (search: Record<string, unknown>): SearchParams => ({
    view: typeof search.view === 'string' ? search.view : undefined,
  }),
  loader: async ({ params }) => {
    try {
      const crmResponse = await crmsApi.get(params.crmId)
      return { crm: crmResponse.data, loaderError: null }
    } catch (error) {
      const status = extractStatus(error)
      // The URL a notification carries: say why it bounced, as the CRM route
      // does, rather than landing on the list with no explanation.
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
  component: ObjectPage,
})

function ObjectPage() {
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

  return (
    <CrmPageContent
      crm={crm}
      crmId={params.crmId}
      search={search}
      initialObjectId={params.objectId}
    />
  )
}
