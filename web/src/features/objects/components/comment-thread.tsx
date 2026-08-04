// Mochi CRMs: Recursive threaded comment component
// Copyright © 2026 Mochisoft OÜ
// SPDX-License-Identifier: AGPL-3.0-only
// This file is part of Mochi, licensed under the GNU AGPL v3 with the
// Mochi Application Interface Exception - see license.txt and license-exception.md.

import { EntityCommentThread, type EntityCommentThreadProps } from "@mochi/web";

type CommentThreadProps = Omit<EntityCommentThreadProps, "containerId"> & {
  crmId: string;
};

export function CommentThread({ crmId, ...props }: CommentThreadProps) {
  return <EntityCommentThread {...props} containerId={crmId} />;
}
