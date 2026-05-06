import { useEffect, useMemo } from "react";
import { useLingui } from '@lingui/react/macro'
import {
  AuthenticatedLayout,
  naturalCompare,
  type SidebarData,
  type NavItem,
} from "@mochi/web";
import { Plus, RefreshCw, Search, Users } from "lucide-react";
import { useCrmsStore } from "@/stores/crms-store";
import { SidebarProvider, useSidebarContext } from "@/context/sidebar-context";
import { CreateCrmDialog } from "@/features/crms/components/create-crm-dialog";
import { APP_ROUTES } from "@/config/routes";

function CrmsLayoutInner() {
  const { t } = useLingui()
  const crms = useCrmsStore((state) => state.crms);
  const isLoading = useCrmsStore((state) => state.isLoading);
  const error = useCrmsStore((state) => state.error);
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
      naturalCompare(a.name, b.name),
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
      title: t`All CRMs`,
      url: "/",
      icon: Users,
    };

    const actionItems: NavItem[] = [
      { title: t`Find CRMs`, icon: Search, url: "/find" },
      { title: t`Create CRM`, icon: Plus, onClick: openCreateDialog },
    ];

    const groups: SidebarData["navGroups"] = [
      {
        title: t`CRMs`,
        items: [
          allCrmsItem,
          ...crmItems,
          ...(error
            ? [
                {
                  title: t`Retry CRMs load`,
                  icon: RefreshCw,
                  onClick: () => {
                    void refresh();
                  },
                  className: "text-destructive",
                },
              ]
            : []),
        ],
      },
      {
        title: "",
        items: actionItems,
        separator: true,
      },
    ];

    return { navGroups: groups };
  }, [crms, openCreateDialog, error, refresh, t]);

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
