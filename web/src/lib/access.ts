// Copyright © 2026 Mochisoft OÜ
// SPDX-License-Identifier: AGPL-3.0-only
// This file is part of Mochi, licensed under the GNU AGPL v3 with the
// Mochi Application Interface Exception - see license.txt and license-exception.md.

// The ladder itself is shared with the projects app, and the shared object page
// gates on the same helpers. CrmAccess is EntityAccess.

export { canComment, canCreate, canDesign, canWrite } from "@mochi/web";
