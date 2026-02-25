import { useEffect, useMemo } from "react";
import {
  AuthenticatedLayout,
  type SidebarData,
  type NavItem,
} from "@mochi/common";
import { Plus, Search, Users } from "lucide-react";
import { useCrmsStore } from "@/stores/crms-store";
import { SidebarProvider, useSidebarContext } from "@/context/sidebar-context";
import { CreateCrmDialog } from "@/features/crms/components/create-crm-dialog";
import { APP_ROUTES } from "@/config/routes";

function CrmsLayoutInner() {
  const crms = useCrmsStore((state) => state.crms);
  const isLoading = useCrmsStore((state) => state.isLoading);
  const refresh = useCrmsStore((state) => state.refresh);
  const {
    createDialogOpen,
    openCreateDialog,
    closeCreateDialog,
  } = useSidebarContext();

  useEffect(() => {
    void refresh();
  }, [refresh]);

  const sidebarData: SidebarData = useMemo(() => {
    const sortedCrms = [...crms].sort((a, b) =>
      a.name.localeCompare(b.name, undefined, { sensitivity: "base" }),
    );

    const crmItems: NavItem[] = sortedCrms.map((crm) => {
      const id = crm.fingerprint ?? crm.id;
      return {
        title: crm.name,
        url: APP_ROUTES.CRMS.VIEW(id),
        icon: Users,
      };
    });

    const allCrmsItem: NavItem = {
      title: "All CRMs",
      url: "/",
      icon: Users,
    };

    const actionItems: NavItem[] = [
      { title: "Find CRMs", icon: Search, url: "/find" },
      { title: "Create CRM", icon: Plus, onClick: openCreateDialog },
    ];

    const groups: SidebarData["navGroups"] = [
      {
        title: "CRMs",
        items: [allCrmsItem, ...crmItems],
      },
      {
        title: "",
        items: actionItems,
        separator: true,
      },
    ];

    return { navGroups: groups };
  }, [crms, openCreateDialog]);

  return (
    <>
      <AuthenticatedLayout
        sidebarData={sidebarData}
        isLoadingSidebar={isLoading && crms.length === 0}
      />
      <CreateCrmDialog
        open={createDialogOpen}
        onOpenChange={(open) => {
          if (!open) closeCreateDialog();
        }}
        hideTrigger
      />
    </>
  );
}

export function CrmsLayout() {
  return (
    <SidebarProvider>
      <CrmsLayoutInner />
    </SidebarProvider>
  );
}
