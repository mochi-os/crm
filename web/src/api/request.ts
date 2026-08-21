// Copyright © 2026 Mochisoft OÜ
// SPDX-License-Identifier: AGPL-3.0-only
// This file is part of Mochi, licensed under the GNU AGPL v3 with the
// Mochi Application Interface Exception - see license.txt and license-exception.md.

// Request client from the shared factory. Do not hand-roll one here: a private
// copy is how this app once lost the same-origin token gate.

import { createAppClient } from "@mochi/web";

export const crmsRequest = createAppClient({ appName: "crm" });
