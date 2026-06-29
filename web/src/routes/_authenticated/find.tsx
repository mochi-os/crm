// Copyright © 2026 Mochi OÜ
// SPDX-License-Identifier: AGPL-3.0-only
// This file is part of Mochi, licensed under the GNU AGPL v3 with the
// Mochi Application Interface Exception - see license.txt and license-exception.md.

import { useCallback, useMemo } from 'react'
import { useLingui } from '@lingui/react/macro'
import { createFileRoute, useNavigate } from '@tanstack/react-router'
import { useQuery } from '@tanstack/react-query'
import { Users } from 'lucide-react'
import { FindEntityPage, toastAction, getErrorMessage, callWithServerFallback } from '@mochi/web'
import { useCrmsStore } from '@/stores/crms-store'
import { APP_ROUTES } from '@/config/routes'
import endpoints from '@/api/endpoints'
import crmsApi from '@/api/crms'

export const Route = createFileRoute('/_authenticated/find')({
  component: FindCrmsPage,
})

function FindCrmsPage() {
  const { t } = useLingui()
  const crms = useCrmsStore((state) => state.crms)
  const refresh = useCrmsStore((state) => state.refresh)
  const navigate = useNavigate()

  // Recommendations query
  const {
    data: recommendationsData,
    isLoading: isLoadingRecommendations,
    isError: isRecommendationsError,
    error: recommendationsError,
    refetch: refetchRecommendations,
  } = useQuery({
    queryKey: ['crms', 'recommendations'],
    queryFn: () => crmsApi.recommendations(),
    retry: false,
    refetchOnWindowFocus: false,
  })
  const recommendations = recommendationsData?.data?.crms ?? []

  const accessibleCrmIds = useMemo(
    () =>
      new Set(
        crms.flatMap((p) =>
          [p.id, p.fingerprint].filter((x): x is string => !!x),
        ),
      ),
    [crms],
  )

  const handleSubscribe = useCallback(
    async (crmId: string, entity: { fingerprint?: string; server?: string }) => {
      try {
        await toastAction(
          callWithServerFallback(
            (server) => crmsApi.subscribe(crmId, server),
            entity.server,
          ),
          {
          loading: t`Subscribing...`,
          success: t`Subscribed`,
          error: (e) => getErrorMessage(e, t`Failed to subscribe`),
        })
        await refresh()
        const id = entity.fingerprint ?? crmId
        await navigate({ to: APP_ROUTES.CRMS.VIEW(id) })
      } catch {
        // toast already shown
      }
    },
    [navigate, refresh, t],
  )

  return (
    <FindEntityPage
      onSubscribe={handleSubscribe}
      subscribedIds={accessibleCrmIds}
      entityClass="crm"
      searchEndpoint={endpoints.crms.search}
      icon={Users}
      iconClassName="bg-primary/10 text-primary"
      title={t`Find CRMs`}
      placeholder={t`Search by name, ID, fingerprint, or URL...`}
      emptyMessage={t`No CRMs found`}
      recommendations={recommendations}
      isLoadingRecommendations={isLoadingRecommendations}
      isRecommendationsError={isRecommendationsError}
      recommendationsError={recommendationsError}
      onRetryRecommendations={() => {
        void refetchRecommendations();
      }}
    />
  )
}
