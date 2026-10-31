// Copyright © 2026 Mochisoft OÜ
// SPDX-License-Identifier: AGPL-3.0-only
// This file is part of Mochi, licensed under the GNU AGPL v3 with the
// Mochi Application Interface Exception - see license.txt and license-exception.md.
import { createFileRoute } from '@tanstack/react-router'
import { useAuthStore } from '@mochi/web'
import { useCrmsStore } from '@/stores/crms-store'
import { CrmsLayout } from '@/components/layout/crms-layout'

export const Route = createFileRoute('/_authenticated')({
  beforeLoad: async () => {
    const store = useAuthStore.getState()
    if (!store.isInitialized) {
      await store.initialize()
    }
  },
  // The sidebar list starts beside the page's own requests rather than when
  // the layout mounts after them. Once a page: a later navigation runs this
  // again and the layout's mount joins it, and neither asks a second time.
  loader: () => {
    void useCrmsStore.getState().load()
  },
  component: CrmsLayout,
})
