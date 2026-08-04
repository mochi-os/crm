// Mochi CRMs: Object attachment display and management
// Copyright © 2026 Mochisoft OÜ
// SPDX-License-Identifier: AGPL-3.0-only
// This file is part of Mochi, licensed under the GNU AGPL v3 with the
// Mochi Application Interface Exception - see license.txt and license-exception.md.

import {
  EntityObjectAttachments,
  type EntityObjectAttachmentsProps,
} from "@mochi/web";
import crmsApi from "@/api/crms";

type ObjectAttachmentsProps = Omit<
  EntityObjectAttachmentsProps,
  "containerId" | "listAttachments" | "uploadAttachments" | "deleteAttachment"
> & { crmId: string };

export function ObjectAttachments({ crmId, ...props }: ObjectAttachmentsProps) {
  return (
    <EntityObjectAttachments
      {...props}
      containerId={crmId}
      listAttachments={crmsApi.listAttachments}
      uploadAttachments={crmsApi.uploadAttachments}
      deleteAttachment={crmsApi.deleteAttachment}
    />
  );
}
