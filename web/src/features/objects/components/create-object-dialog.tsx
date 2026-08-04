// Mochi CRMs: Create object dialog component
// Copyright © 2026 Mochisoft OÜ
// SPDX-License-Identifier: AGPL-3.0-only
// This file is part of Mochi, licensed under the GNU AGPL v3 with the
// Mochi Application Interface Exception - see license.txt and license-exception.md.

import { Trans } from "@lingui/react/macro";
import {
  EntityCreateObjectDialog,
  type EntityCreateObjectDialogProps,
} from "@mochi/web";
import crmsApi from "@/api/crms";
import type { CrmDetails, CrmObject } from "@/types";

type CreateObjectDialogProps = Omit<
  EntityCreateObjectDialogProps<CrmObject>,
  | "containerId"
  | "recordId"
  | "design"
  | "prefix"
  | "srTitle"
  | "srDescription"
  | "buildObject"
  | "listObjects"
  | "listPeople"
  | "createObject"
  | "setValue"
  | "uploadAttachments"
  | "searchUsers"
> & { crmId: string; crm: CrmDetails };

export function CreateObjectDialog({ crmId, crm, ...props }: CreateObjectDialogProps) {
  return (
    <EntityCreateObjectDialog
      {...props}
      containerId={crmId}
      recordId={crm.crm.id}
      design={crm}
      srTitle={<Trans>Create object</Trans>}
      srDescription={<Trans>Create a new CRM object.</Trans>}
      buildObject={(base) => ({ ...base, crm: crm.crm.id })}
      listObjects={crmsApi.listObjects}
      listPeople={crmsApi.listPeople}
      createObject={crmsApi.createObject}
      setValue={crmsApi.setValue}
      uploadAttachments={crmsApi.uploadAttachments}
      searchUsers={crmsApi.searchUsers}
    />
  );
}
