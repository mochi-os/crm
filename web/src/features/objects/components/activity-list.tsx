// Mochi Crms: Activity list component
// Copyright © 2026 Mochisoft OÜ
// SPDX-License-Identifier: AGPL-3.0-only
// This file is part of Mochi, licensed under the GNU AGPL v3 with the
// Mochi Application Interface Exception - see license.txt and license-exception.md.

import { EntityActivityList, type EntityField } from "@mochi/web";
import crmsApi from "@/api/crms";

interface ActivityListProps {
  crmId: string;
  objectId: string;
  fields?: EntityField[];
}

export function ActivityList({ crmId, objectId, fields }: ActivityListProps) {
  return (
    <EntityActivityList
      containerId={crmId}
      objectId={objectId}
      fields={fields}
      listActivity={crmsApi.listActivity}
    />
  );
}
