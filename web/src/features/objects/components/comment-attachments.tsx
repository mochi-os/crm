// Mochi CRMs: Comment attachment display
// Copyright © 2026 Mochisoft OÜ
// SPDX-License-Identifier: AGPL-3.0-only
// This file is part of Mochi, licensed under the GNU AGPL v3 with the
// Mochi Application Interface Exception - see license.txt and license-exception.md.

import { EntityCommentAttachments } from "@mochi/web";
import type { CommentAttachment } from "@/types";

interface CommentAttachmentsProps {
  attachments: CommentAttachment[];
  crmId: string;
}

export function CommentAttachments({ attachments, crmId }: CommentAttachmentsProps) {
  return (
    <EntityCommentAttachments attachments={attachments} containerId={crmId} />
  );
}
