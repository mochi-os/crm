// Copyright © 2026 Mochisoft OÜ
// SPDX-License-Identifier: AGPL-3.0-only
// This file is part of Mochi, licensed under the GNU AGPL v3 with the
// Mochi Application Interface Exception - see license.txt and license-exception.md.

import { Trans, useLingui } from "@lingui/react/macro";
import { Link } from "@tanstack/react-router";
import { EntityListPage } from "@mochi/web/components/entity/entity-list-page";
import { Users } from "lucide-react";
import { useCrmsStore } from "@/stores/crms-store";
import { useSidebarContext } from "@/context/sidebar-context";
import { InlineCrmSearch } from "../components/inline-crm-search";
import { RecommendedCrms } from "../components/recommended-crms";
import crmsApi from "@/api/crms";

export function CrmsListPage() {
  const { t } = useLingui();
  const crms = useCrmsStore((state) => state.crms);
  const isLoading = useCrmsStore((state) => state.isLoading);
  const error = useCrmsStore((state) => state.error);
  const refresh = useCrmsStore((state) => state.refresh);
  const { openCreateDialog } = useSidebarContext();

  return (
    <EntityListPage
      rows={crms}
      isLoading={isLoading}
      error={error}
      refresh={refresh}
      icon={Users}
      onCreate={openCreateDialog}
      unsubscribe={(crmId) => crmsApi.unsubscribe(crmId)}
      invalidateKey="crms"
      labels={{
        title: t`CRMs`,
        emptyDescription: t`You have no CRMs yet.`,
        createAction: t`Create a new CRM`,
        rowActions: t`CRM actions`,
        unsubscribe: t`Unsubscribe`,
        unsubscribeConfirmation: t`Are you sure you want to unsubscribe from this CRM?`,
        unsubscribing: t`Unsubscribing...`,
        unsubscribed: t`Unsubscribed`,
        unsubscribeFailed: t`Failed to unsubscribe`,
      }}
      renderLink={(crm, className) => (
        <Link
          preload={false}
          to="/$crmId"
          params={{ crmId: crm.fingerprint }}
          className={className}
        >
          <span className="sr-only">
            <Trans>Open {crm.name}</Trans>
          </span>
        </Link>
      )}
      renderSearch={(subscribedIds) => (
        <InlineCrmSearch subscribedIds={subscribedIds} />
      )}
      renderRecommended={(subscribedIds) => (
        <RecommendedCrms
          subscribedIds={subscribedIds}
          onSubscribe={() => void refresh()}
        />
      )}
    />
  );
}
