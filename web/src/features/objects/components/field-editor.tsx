// Mochi CRMs: Field editor component
// Copyright © 2026 Mochisoft OÜ
// SPDX-License-Identifier: AGPL-3.0-only
// This file is part of Mochi, licensed under the GNU AGPL v3 with the
// Mochi Application Interface Exception - see license.txt and license-exception.md.

import { EntityFieldEditor } from '@mochi/web'
import type { ComponentProps } from 'react'
import crmsApi from '@/api/crms'

type FieldEditorProps = Omit<
  ComponentProps<typeof EntityFieldEditor>,
  'searchUsers'
>

export function FieldEditor(props: FieldEditorProps) {
  return (
    <EntityFieldEditor
      {...props}
      searchUsers={async (q) => (await crmsApi.searchUsers(q)).data.results}
    />
  )
}
