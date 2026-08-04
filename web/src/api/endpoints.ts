// Copyright © 2026 Mochisoft OÜ
// SPDX-License-Identifier: AGPL-3.0-only
// This file is part of Mochi, licensed under the GNU AGPL v3 with the
// Mochi Application Interface Exception - see license.txt and license-exception.md.

// Endpoints are relative to baseURL which is already set to /crm/ in request.ts.
// The CRM server exposes exactly the shared object/class/field routes and
// nothing beyond them, so the table is the shared table unchanged.

import { entityEndpoints } from "@mochi/web";

const endpoints = {
  crms: entityEndpoints,
} as const;

export default endpoints;
