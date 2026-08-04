// Mochi CRMs: Board column component
// Copyright © 2026 Mochisoft OÜ
// SPDX-License-Identifier: AGPL-3.0-only
// This file is part of Mochi, licensed under the GNU AGPL v3 with the
// Mochi Application Interface Exception - see license.txt and license-exception.md.

import {
  EntityBoardColumn,
  type EntityBoardColumnProps,
  type EntityBoardColumnRow,
} from "@mochi/web";
import { useLingui } from "@lingui/react/macro";
import type { CrmObject } from "@/types";

export type BoardColumnRow = EntityBoardColumnRow<CrmObject>;

type BoardColumnProps = Omit<
  EntityBoardColumnProps<CrmObject>,
  "fallbackTitle" | "containerId"
> & { crmId?: string };

export function BoardColumn({ crmId, ...props }: BoardColumnProps) {
  const { t } = useLingui();
  return (
    <EntityBoardColumn
      {...props}
      containerId={crmId}
      fallbackTitle={() => t`Untitled`}
    />
  );
}
