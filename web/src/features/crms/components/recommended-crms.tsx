// Copyright © 2026 Mochisoft OÜ
// SPDX-License-Identifier: AGPL-3.0-only
// This file is part of Mochi, licensed under the GNU AGPL v3 with the
// Mochi Application Interface Exception - see license.txt and license-exception.md.

import { Trans, useLingui } from "@lingui/react/macro";
import { Users } from "lucide-react";
import {
  RecommendedEntities,
  toastAction,
  getErrorMessage,
  type RecommendedEntityItem,
} from "@mochi/web";
import crmsApi from "@/api/crms";

interface RecommendedCrmsProps {
  subscribedIds: Set<string>;
  onSubscribe: () => void;
}

interface RecommendedCrm extends RecommendedEntityItem {
  blurb: string;
  fingerprint: string;
  server: string;
}

export function RecommendedCrms({
  subscribedIds,
  onSubscribe,
}: RecommendedCrmsProps) {
  const { t } = useLingui();

  const load = async (): Promise<RecommendedCrm[]> => {
    const response = await crmsApi.recommendations();
    return response.data?.crms ?? [];
  };

  const handleSubscribe = async (crm: RecommendedCrm) => {
    await toastAction(crmsApi.subscribe(crm.id, crm.server || undefined), {
      loading: t`Subscribing...`,
      success: t`Subscribed to ${crm.name}`,
      error: (e) => getErrorMessage(e, t`Failed to subscribe`),
    });
    onSubscribe();
  };

  return (
    <RecommendedEntities
      subscribedIds={subscribedIds}
      load={load}
      onSubscribe={handleSubscribe}
      icon={Users}
      title={<Trans>Recommended CRMs</Trans>}
      errorMessage={t`Failed to load recommended CRMs`}
      subscribeLabel={t`Subscribe`}
    />
  );
}
