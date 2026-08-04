// Mochi CRMs: Tree view component
// Copyright © 2026 Mochisoft OÜ
// SPDX-License-Identifier: AGPL-3.0-only
// This file is part of Mochi, licensed under the GNU AGPL v3 with the
// Mochi Application Interface Exception - see license.txt and license-exception.md.

// Binding for the shared tree view. CRMs issue no readable ids, so no prefix is
// passed and the ID column stays off.

import { EntityTreeView, type EntityTreeNode, type EntityTreeViewProps } from "@mochi/web";
import type { CrmDetails, CrmObject } from "@/types";

export type TreeNode = EntityTreeNode<CrmObject>;

type TreeViewProps = Omit<
  EntityTreeViewProps<CrmObject>,
  "design" | "containerId" | "storagePrefix" | "prefix"
> & {
  crm: CrmDetails;
  crmId: string;
};

export function TreeView({ crm, crmId, ...props }: TreeViewProps) {
  return (
    <EntityTreeView
      {...props}
      design={crm}
      containerId={crmId}
      storagePrefix="crms"
    />
  );
}
