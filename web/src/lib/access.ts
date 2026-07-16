// Copyright © 2026 Mochisoft OÜ
// SPDX-License-Identifier: AGPL-3.0-only
// This file is part of Mochi, licensed under the GNU AGPL v3 with the
// Mochi Application Interface Exception - see license.txt and license-exception.md.

import type { CrmAccess } from "@/types";

export const canDesign = (a: CrmAccess) => a === "owner" || a === "design";
export const canWrite = (a: CrmAccess) => canDesign(a) || a === "write";
export const canCreate = canWrite;
export const canComment = (a: CrmAccess) => canWrite(a) || a === "comment";
