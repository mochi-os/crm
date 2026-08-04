// Mochi CRMs: Object link display and management
// Copyright © 2026 Mochisoft OÜ
// SPDX-License-Identifier: AGPL-3.0-only
// This file is part of Mochi, licensed under the GNU AGPL v3 with the
// Mochi Application Interface Exception - see license.txt and license-exception.md.

// Binding for the shared link panel. CRMs issue no readable ids, so no prefix
// is passed and a linked object with no title falls back to "Untitled".

import { EntityObjectLinks, type EntityObjectLinksProps } from "@mochi/web";
import crmsApi from "@/api/crms";
import type { CrmObject } from "@/types";

type ObjectLinksProps = Omit<
  EntityObjectLinksProps<CrmObject>,
  "containerId" | "prefix" | "listObjects" | "createLink" | "deleteLink"
> & { crmId: string };

export function ObjectLinks({ crmId, ...props }: ObjectLinksProps) {
  return (
    <EntityObjectLinks
      {...props}
      containerId={crmId}
      listObjects={crmsApi.listObjects}
      createLink={crmsApi.createLink}
      deleteLink={crmsApi.deleteLink}
    />
  );
}
