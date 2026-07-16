// Mochi CRMs: Comment attachment display
// Copyright © 2026 Mochisoft OÜ
// SPDX-License-Identifier: AGPL-3.0-only
// This file is part of Mochi, licensed under the GNU AGPL v3 with the
// Mochi Application Interface Exception - see license.txt and license-exception.md.

import {
  AttachmentGallery,
  getAppPath,
  authenticatedUrl,
} from "@mochi/web";
import type { CommentAttachment } from "@/types";

interface CommentAttachmentsProps {
  attachments: CommentAttachment[];
  crmId: string;
}

export function CommentAttachments({
  attachments,
  crmId,
}: CommentAttachmentsProps) {
  if (!attachments || attachments.length === 0) return null;

  const basePath = `${getAppPath()}/${crmId}/-/attachments/`;
  const attUrl = (id: string, suffix = "") => authenticatedUrl(`${basePath}${id}${suffix}`);

  return (
    <div className="mt-1">
      <AttachmentGallery
        attachments={attachments}
        getUrl={(att) => attUrl(att.id)}
        getThumbnailUrl={(att) => attUrl(att.id, "/thumbnail")}
        rowHeight={80}
      />
    </div>
  );
}
