// Mochi CRMs: Board card component
// Copyright © 2026 Mochisoft OÜ
// SPDX-License-Identifier: AGPL-3.0-only
// This file is part of Mochi, licensed under the GNU AGPL v3 with the
// Mochi Application Interface Exception - see license.txt and license-exception.md.

import { EntityBoardCard, type EntityBoardCardProps } from '@mochi/web'
import { useLingui } from '@lingui/react/macro'
import type { CrmObject } from '@/types'

type BoardCardProps = Omit<
  EntityBoardCardProps<CrmObject>,
  'fallbackTitle' | 'containerId'
> & { crmId?: string }

export function BoardCard({ crmId, ...props }: BoardCardProps) {
  const { t } = useLingui()
  return (
    <EntityBoardCard
      {...props}
      containerId={crmId}
      fallbackTitle={() => t`Untitled`}
    />
  )
}
