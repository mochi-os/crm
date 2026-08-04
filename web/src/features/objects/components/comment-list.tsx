// Mochi CRMs: Threaded comment list component
// Copyright © 2026 Mochisoft OÜ
// SPDX-License-Identifier: AGPL-3.0-only
// This file is part of Mochi, licensed under the GNU AGPL v3 with the
// Mochi Application Interface Exception - see license.txt and license-exception.md.

import { EntityCommentList, type EntityCommentListProps } from "@mochi/web";
import crmsApi from "@/api/crms";

type CommentListProps = Omit<
  EntityCommentListProps,
  | "containerId"
  | "listComments"
  | "listPeople"
  | "createComment"
  | "updateComment"
  | "deleteComment"
> & { crmId: string };

export function CommentList({ crmId, ...props }: CommentListProps) {
  return (
    <EntityCommentList
      {...props}
      containerId={crmId}
      listComments={crmsApi.listComments}
      listPeople={crmsApi.listPeople}
      createComment={crmsApi.createComment}
      updateComment={crmsApi.updateComment}
      deleteComment={crmsApi.deleteComment}
    />
  );
}
