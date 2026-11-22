// Copyright © 2026 Mochisoft OÜ
// SPDX-License-Identifier: AGPL-3.0-only
// This file is part of Mochi, licensed under the GNU AGPL v3 with the
// Mochi Application Interface Exception - see license.txt and license-exception.md.
import { useLingui } from '@lingui/react/macro'
import type { ShareLabels } from '@mochi/web'

/** Share's words, the same in every app so one translation serves them all. */
export function useShareLabels(): ShareLabels {
  const { t } = useLingui()
  return {
    feed: t`Post to a feed`,
    chat: t`Send in a chat`,
    copy: t`Copy link`,
  }
}
