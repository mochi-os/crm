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
