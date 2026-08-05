// Copyright © 2026 Mochisoft OÜ
// SPDX-License-Identifier: AGPL-3.0-only
// This file is part of Mochi, licensed under the GNU AGPL v3 with the
// Mochi Application Interface Exception - see license.txt and license-exception.md.

import { useLingui } from "@lingui/react/macro";
import { useNavigate } from "@tanstack/react-router";
import { Users } from "lucide-react";
import {
  InlineEntitySearch,
  toastAction,
  getErrorMessage,
  type InlineEntitySearchItem,
} from "@mochi/web";
import crmsApi from "@/api/crms";
import { useCrmsStore } from "@/stores/crms-store";

interface DirectoryEntry extends InlineEntitySearchItem {
  fingerprint: string;
  location?: string;
  /** owner's peer from a mochi:// share-link probe; subscribe pins the same peer. */
  peer?: string;
}

interface InlineCrmSearchProps {
  subscribedIds: Set<string>;
  onRefresh?: () => void;
}

export function InlineCrmSearch({
  subscribedIds,
  onRefresh,
}: InlineCrmSearchProps) {
  const { t } = useLingui();
  const navigate = useNavigate();
  const refresh = useCrmsStore((state) => state.refresh);

  const search = async (query: string): Promise<DirectoryEntry[]> => {
    const response = await crmsApi.search({ search: query });
    return response.data ?? [];
  };

  const probe = async (url: string): Promise<DirectoryEntry[]> => {
    const probed = await crmsApi.probe(url);
    const data = probed?.data;
    return data?.id
      ? [
          {
            id: data.id,
            name: data.name ?? "",
            fingerprint: data.fingerprint ?? "",
            location: data.server ?? "",
            peer: data.peer,
          },
        ]
      : [];
  };

  const handleSubscribe = async (crm: DirectoryEntry) => {
    await toastAction(
      crmsApi.subscribe(crm.id, crm.location || undefined, crm.peer),
      {
        loading: t`Subscribing...`,
        success: t`Subscribed`,
        error: (e) => getErrorMessage(e, t`Failed to subscribe`),
      },
    );
    void refresh();
    onRefresh?.();
    void navigate({
      to: "/$crmId",
      params: { crmId: crm.fingerprint || crm.id },
    });
  };

  return (
    <InlineEntitySearch
      subscribedIds={subscribedIds}
      search={search}
      probe={probe}
      onSubscribe={handleSubscribe}
      icon={Users}
      placeholder={t`Search for CRMs...`}
      emptyMessage={t`No CRMs found`}
      searchErrorMessage={t`Failed to search CRMs`}
      subscribeLabel={t`Subscribe`}
    />
  );
}
