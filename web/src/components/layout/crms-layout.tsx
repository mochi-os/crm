// Copyright © 2026 Mochisoft OÜ
// SPDX-License-Identifier: AGPL-3.0-only
// This file is part of Mochi, licensed under the GNU AGPL v3 with the
// Mochi Application Interface Exception - see license.txt and license-exception.md.

import { useLingui } from "@lingui/react/macro";
import { EntityLayout } from "@mochi/web/components/entity/entity-layout";
import { Users } from "lucide-react";
import { useCrmsStore } from "@/stores/crms-store";
import { SidebarProvider, useSidebarContext } from "@/context/sidebar-context";
import { CreateCrmDialog } from "@/features/crms/components/create-crm-dialog";
import { APP_ROUTES } from "@/config/routes";

function CrmsLayoutInner() {
  const { t } = useLingui();
  const crms = useCrmsStore((state) => state.crms);
  const isLoading = useCrmsStore((state) => state.isLoading);
  const error = useCrmsStore((state) => state.error);
  const refresh = useCrmsStore((state) => state.refresh);
  const { createDialogOpen, openCreateDialog, closeCreateDialog } =
    useSidebarContext();

  return (
    <EntityLayout
      rows={crms}
      isLoading={isLoading}
      error={error}
      refresh={refresh}
      icon={Users}
      onCreate={openCreateDialog}
      viewUrl={APP_ROUTES.CRMS.VIEW}
      labels={{
        group: t`CRMs`,
        all: t`All CRMs`,
        find: t`Find CRMs`,
        create: t`Create CRM`,
        retry: t`Retry CRMs load`,
      }}
    >
      <CreateCrmDialog
        open={createDialogOpen}
        onOpenChange={(open) => {
          if (!open) closeCreateDialog();
        }}
        hideTrigger
      />
    </EntityLayout>
  );
}

export function CrmsLayout() {
  return (
    <SidebarProvider>
      <CrmsLayoutInner />
    </SidebarProvider>
  );
}
