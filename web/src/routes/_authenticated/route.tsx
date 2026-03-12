import { createFileRoute } from "@tanstack/react-router";
import { useAuthStore } from "@mochi/common";
import { CrmsLayout } from "@/components/layout/crms-layout";

export const Route = createFileRoute("/_authenticated")({
  beforeLoad: async () => {
    const store = useAuthStore.getState();
    if (!store.isInitialized) {
      await store.initialize();
    }
  },
  component: CrmsLayout,
});
