// Copyright © 2026 Mochisoft OÜ
// SPDX-License-Identifier: AGPL-3.0-only
// This file is part of Mochi, licensed under the GNU AGPL v3 with the
// Mochi Application Interface Exception - see license.txt and license-exception.md.

// The store itself is createEntityListStore in @mochi/web, shared with the
// projects app. Only the list call, the response key and the wording are ours.

import { createEntityListStore } from "@mochi/web";
import { t } from '@lingui/core/macro'
import type { Crm } from "@/types";
import crmsApi from "@/api/crms";

export const useCrmsStore = createEntityListStore<Crm>({
  list: crmsApi.list,
  listKey: "crms",
  errorMessage: () => t`Failed to load CRMs`,
});
