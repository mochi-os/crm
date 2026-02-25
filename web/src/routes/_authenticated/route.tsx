import { createFileRoute } from "@tanstack/react-router";
import { useAuthStore } from "@mochi/common";
import { CrmsLayout } from "@/components/layout/crms-layout";

export const Route = createFileRoute("/_authenticated")({
  beforeLoad: async () => {
    // Initialize auth state from cookies if available
    const store = useAuthStore.getState();

    if (!store.isInitialized) {
      store.initialize();
    }

    return;
  },
  component: CrmsLayout,
});
