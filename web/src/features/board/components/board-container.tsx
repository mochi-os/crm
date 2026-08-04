// Mochi CRMs: Board container component
// Copyright © 2026 Mochisoft OÜ
// SPDX-License-Identifier: AGPL-3.0-only
// This file is part of Mochi, licensed under the GNU AGPL v3 with the
// Mochi Application Interface Exception - see license.txt and license-exception.md.

import {
  EntityBoardContainer,
  type EntityBoardContainerProps,
  type EntityDragPreview,
} from "@mochi/web";
import { useLingui } from "@lingui/react/macro";
import type { CrmObject, CrmDetails } from "@/types";

export type DragPreview = EntityDragPreview;

type BoardContainerProps = Omit<
  EntityBoardContainerProps<CrmObject>,
  "design" | "containerId" | "fallbackTitle"
> & { crm: CrmDetails };

export function BoardContainer({ crm, ...props }: BoardContainerProps) {
  const { t } = useLingui();
  return (
    <EntityBoardContainer
      {...props}
      design={crm}
      containerId={crm.crm.id}
      fallbackTitle={() => t`Untitled`}
    />
  );
}
