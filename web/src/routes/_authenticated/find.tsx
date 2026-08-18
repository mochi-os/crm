// Copyright © 2026 Mochisoft OÜ
// SPDX-License-Identifier: AGPL-3.0-only
// This file is part of Mochi, licensed under the GNU AGPL v3 with the
// Mochi Application Interface Exception - see license.txt and license-exception.md.

// The wiring around FindEntityPage is EntityFindPage in @mochi/web, shared with
// the projects app. What stays here is the route, the wording and the icon.

import { useLingui } from '@lingui/react/macro'
import { createFileRoute, useNavigate } from '@tanstack/react-router'
import { Users } from 'lucide-react'
import { EntityFindPage } from '@mochi/web'
import { useCrmsStore } from '@/stores/crms-store'
import { APP_ROUTES } from '@/config/routes'
import endpoints from '@/api/endpoints'
import crmsApi from '@/api/crms'

export const Route = createFileRoute('/_authenticated/find')({
  component: FindCrmsPage,
})

function FindCrmsPage() {
  const { t } = useLingui()
  const rows = useCrmsStore((state) => state.rows)
  const refresh = useCrmsStore((state) => state.refresh)
  const navigate = useNavigate()

  return (
    <EntityFindPage
      api={crmsApi}
      listKey="crms"
      queryKey="crms"
      rows={rows}
      refresh={refresh}
      entityClass="crm"
      searchEndpoint={endpoints.crms.search}
      icon={Users}
      iconClassName="bg-primary/10 text-primary"
      onOpen={(id) => navigate({ to: APP_ROUTES.CRMS.VIEW(id) })}
      labels={{
        title: t`Find CRMs`,
        placeholder: t`Search by name, ID, fingerprint, or URL...`,
        emptyMessage: t`No CRMs found`,
        subscribing: t`Subscribing...`,
        subscribed: t`Subscribed`,
        subscribeFailed: t`Failed to subscribe`,
      }}
    />
  )
}
