// Copyright © 2026 Mochisoft OÜ
// SPDX-License-Identifier: AGPL-3.0-only
// This file is part of Mochi, licensed under the GNU AGPL v3 with the
// Mochi Application Interface Exception - see license.txt and license-exception.md.

import { create } from "zustand";
import { getErrorMessage } from "@mochi/web";
import { t } from '@lingui/core/macro'
import type { Crm } from "@/types";
import crmsApi from "@/api/crms";

interface CrmsState {
  crms: Crm[];
  isLoading: boolean;
  error: string | null;
  refresh: () => Promise<void>;
}

export const useCrmsStore = create<CrmsState>()((set) => ({
  crms: [],
  isLoading: false,
  error: null,

  refresh: async () => {
    set({ isLoading: true, error: null });
    try {
      const response = await crmsApi.list();
      const crms = response.data?.crms ?? [];
      set({ crms, isLoading: false });
    } catch (error) {
      set({ error: getErrorMessage(error, t`Failed to load CRMs`), isLoading: false });
    }
  },
}));
