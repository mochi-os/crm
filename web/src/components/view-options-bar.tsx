// Mochi CRMs: Collapsible view options bar
// Copyright © 2026 Mochisoft OÜ
// SPDX-License-Identifier: AGPL-3.0-only
// This file is part of Mochi, licensed under the GNU AGPL v3 with the
// Mochi Application Interface Exception - see license.txt and license-exception.md.

import { EntityViewOptionsBar, type EntityViewOptionsBarProps } from "@mochi/web";
import type { CrmDetails } from "@/types";

// CRMs issue no object numbers, so `numbered` is left off and the built-in
// Number sort stays out of the dropdown.
type ViewOptionsBarProps = Omit<
  EntityViewOptionsBarProps,
  "views" | "numbered"
> & {
  crm: CrmDetails;
};

export function ViewOptionsBar({ crm, ...props }: ViewOptionsBarProps) {
  return <EntityViewOptionsBar {...props} views={crm.views} />;
}
