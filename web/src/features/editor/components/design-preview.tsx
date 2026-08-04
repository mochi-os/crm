// Mochi CRMs: Design preview component
// Copyright © 2026 Mochisoft OÜ
// SPDX-License-Identifier: AGPL-3.0-only
// This file is part of Mochi, licensed under the GNU AGPL v3 with the
// Mochi Application Interface Exception - see license.txt and license-exception.md.

import { EntityDesignPreview } from "@mochi/web";
import { useLingui } from "@lingui/react/macro";
import type { CrmDetails, CrmObject } from "@/types";

interface DesignPreviewProps {
  crm: CrmDetails;
  crmId: string;
  objects: CrmObject[];
  selectedClassId: string | null;
}

export function DesignPreview({ crm, crmId, objects, selectedClassId }: DesignPreviewProps) {
  const { t } = useLingui();
  return (
    <EntityDesignPreview
      design={crm}
      objects={objects}
      selectedClassId={selectedClassId}
      boardContainerId={crm.crm.id}
      treeContainerId={crmId}
      storagePrefix="crms"
      fallbackTitle={() => t`Untitled`}
    />
  );
}
