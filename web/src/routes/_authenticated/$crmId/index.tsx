// Mochi CRM: CRM page with board and tree views
// Copyright © 2026 Mochisoft OÜ
// SPDX-License-Identifier: AGPL-3.0-only
// This file is part of Mochi, licensed under the GNU AGPL v3 with the
// Mochi Application Interface Exception - see license.txt and license-exception.md.

// The page body is EntityObjectsPage in @mochi/web, shared with the projects
// app. What stays here is the route, the loader, the wording, and the bindings
// the shared page renders through its slots.

import { useEffect } from "react";
import { useLingui } from '@lingui/react/macro'
import { t } from '@lingui/core/macro'
import { createFileRoute, Link, redirect, useNavigate, useRouter } from "@tanstack/react-router";
import {
  DropdownMenuItem,
  EntityObjectsPage,
  GeneralError,
  extractStatus,
  getErrorMessage,
  Main,
  PageHeader,
  toast,
} from "@mochi/web";
import { Settings, Settings2, Users } from "lucide-react";
import crmsApi from "@/api/crms";
import type { CrmDetails, CrmObject } from "@/types";
import { useCrmsStore } from "@/stores/crms-store";
import { BoardContainer } from "@/features/board/components";
import { TreeView } from "@/features/tree";
import {
  CreateObjectDialog,
  ObjectDetailPanel,
} from "@/features/objects/components";
import { ViewOptionsBar } from "@/components/view-options-bar";

interface SearchParams {
  view?: string;
}

export const Route = createFileRoute("/_authenticated/$crmId/")({
  validateSearch: (search: Record<string, unknown>): SearchParams => ({
    view: typeof search.view === "string" ? search.view : undefined,
  }),
  loader: async ({ params }) => {
    try {
      const crmResponse = await crmsApi.get(params.crmId);
      return { crm: crmResponse.data, loaderError: null, loaderStatus: null };
    } catch (error) {
      const status = extractStatus(error);
      if (status === 403) {
        return { crm: null as CrmDetails | null, loaderError: null, loaderStatus: 403 };
      }
      if (status === 404) {
        throw redirect({ to: "/" });
      }

      return {
        crm: null as CrmDetails | null,
        loaderError: getErrorMessage(error, t`Failed to load CRM`),
        loaderStatus: status,
      };
    }
  },
  component: CrmPage,
});

function CrmPage() {
  const { t } = useLingui()
  const { crm, loaderError, loaderStatus } = Route.useLoaderData() as {
    crm: CrmDetails | null;
    loaderError: string | null;
    loaderStatus: number | null;
  };
  const params = Route.useParams();
  const search = Route.useSearch();
  const navigate = useNavigate();
  const router = useRouter();

  useEffect(() => {
    if (loaderStatus === 403) {
      toast.error(t`You don't have access to this CRM.`);
      void navigate({ to: "/" });
    }
  // eslint-disable-next-line react-hooks/exhaustive-deps
  }, []);

  if (loaderStatus === 403) return null;

  if (!crm) {
    return (
      <>
        <PageHeader
          title="CRM"
          icon={<Users className="size-4 md:size-5" />}
          back={{ label: t`Back to CRMs`, onFallback: () => navigate({ to: "/" }) }}
        />
        <Main>
          <GeneralError
            error={new Error(loaderError ?? "Failed to load CRM")}
            minimal
            mode="inline"
            reset={() => void router.invalidate()}
          />
        </Main>
      </>
    );
  }

  return (
    <CrmPageContent
      crm={crm}
      crmId={params.crmId}
      search={search}
    />
  );
}

export interface CrmPageContentProps {
  crm: CrmDetails;
  crmId: string;
  search: SearchParams;
  initialObjectId?: string;
}

export function CrmPageContent({ crm, crmId, search, initialObjectId }: CrmPageContentProps) {
  const { t } = useLingui()
  const navigate = useNavigate();
  const refreshSidebar = useCrmsStore((state) => state.refresh);

  return (
    <EntityObjectsPage<CrmObject>
      design={crm}
      container={crm.crm}
      containerId={crmId}
      search={search}
      initialObjectId={initialObjectId}
      icon={Users}
      api={crmsApi}
      entity="crm"
      storagePrefix="crms"
      listKey="crms"
      backupSlug="crm"
      refreshSidebar={refreshSidebar}
      onLeave={() => void navigate({ to: "/" })}
      // An empty CRM opens on its companies view: the first thing to add is a
      // company, and the default view has nothing to show until one exists.
      emptyViewClass="company"
      labels={{
        pageActions: t`Open page actions`,
        createShort: t`New`,
        // `className.toLowerCase()` rather than a variable, so the extracted
        // message keeps the positional placeholder this app already ships.
        createAction: (className) =>
          className ? t`New ${className.toLowerCase()}` : t`New`,
        noClasses: t`Please add one or more classes to the CRM design.`,
        viewOptions: t`View options`,
        addColumn: t`Add column`,
        reorderColumns: t`Re-order columns`,
        reorderHint: t`Drag columns to re-order them`,
        cancel: t`Cancel`,
        save: t`Save`,
        boardHint: t`Double click on a column to add content`,
        dismissBoardHint: t`Dismiss board hint`,
        exportData: t`Export data`,
        loading: t`Loading...`,
        downloaded: (filename) => t`Downloaded ${filename}`,
        exportFailed: t`Failed to export data`,
        shareAction: t`Link`,
        shareTitle: t`CRM link`,
        shareFailed: t`Failed to create link`,
        unsubscribe: t`Unsubscribe`,
        unsubscribeTitle: t`Unsubscribe from CRM?`,
        unsubscribeDescription: t`This will remove "${crm.crm.name}" from your sidebar and stop updates for this CRM.`,
        unsubscribing: t`Unsubscribing...`,
        unsubscribed: t`Unsubscribed`,
        unsubscribeFailed: t`Failed to unsubscribe`,
      }}
      csvExport={{
        menuAction: t`Export CSV`,
        noObjects: t`No objects to export.`,
        idColumn: t`ID`,
        classColumn: t`Class`,
        parentColumn: t`Parent`,
      }}
      designMenuItem={
        <DropdownMenuItem asChild>
          <Link to="/$crmId/design" params={{ crmId }}>
            <Settings2 className="size-4 me-2" />
            {t`Design`}
          </Link>
        </DropdownMenuItem>
      }
      settingsMenuItem={
        <DropdownMenuItem asChild>
          <Link to="/$crmId/settings" params={{ crmId }}>
            <Settings className="size-4 me-2" />
            {t`Settings`}
          </Link>
        </DropdownMenuItem>
      }
      renderViewOptionsBar={(props) => <ViewOptionsBar crm={crm} {...props} />}
      renderBoard={(props) => <BoardContainer crm={crm} {...props} />}
      renderTree={(props) => <TreeView crm={crm} crmId={crmId} {...props} />}
      renderCreateDialog={(props) => (
        <CreateObjectDialog crmId={crmId} crm={crm} {...props} />
      )}
      renderDetailPanel={({ objectId, onClose }) => (
        <ObjectDetailPanel
          crmId={crmId}
          objectId={objectId}
          crm={crm}
          access={crm.crm.access}
          onClose={onClose}
        />
      )}
    />
  );
}
