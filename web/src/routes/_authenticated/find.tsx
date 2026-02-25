import { useCallback, useMemo } from 'react'
import { createFileRoute, useNavigate } from '@tanstack/react-router'
import { useQuery } from '@tanstack/react-query'
import { Users } from 'lucide-react'
import { FindEntityPage } from '@mochi/common'
import { useCrmsStore } from '@/stores/crms-store'
import { APP_ROUTES } from '@/config/routes'
import endpoints from '@/api/endpoints'
import crmsApi from '@/api/crms'

export const Route = createFileRoute('/_authenticated/find')({
  component: FindCrmsPage,
})

function FindCrmsPage() {
  const crms = useCrmsStore((state) => state.crms)
  const refresh = useCrmsStore((state) => state.refresh)
  const navigate = useNavigate()

  // Recommendations query
  const {
    data: recommendationsData,
    isLoading: isLoadingRecommendations,
    isError: isRecommendationsError,
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
      await crmsApi.subscribe(crmId, entity.server)
      await refresh()
      const id = entity.fingerprint ?? crmId
      await navigate({ to: APP_ROUTES.CRMS.VIEW(id) })
    },
    [navigate, refresh],
  )

  return (
    <FindEntityPage
      onSubscribe={handleSubscribe}
      subscribedIds={accessibleCrmIds}
      entityClass="crm"
      searchEndpoint={endpoints.crms.search}
      icon={Users}
      iconClassName="bg-blue-500/10 text-blue-600"
      title="Find CRMs"
      placeholder="Search by name, ID, fingerprint, or URL..."
      emptyMessage="No CRMs found"
      recommendations={recommendations}
      isLoadingRecommendations={isLoadingRecommendations}
      isRecommendationsError={isRecommendationsError}
    />
  )
}
