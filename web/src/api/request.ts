// Copyright © 2026 Mochisoft OÜ
// SPDX-License-Identifier: AGPL-3.0-only
// This file is part of Mochi, licensed under the GNU AGPL v3 with the
// Mochi Application Interface Exception - see license.txt and license-exception.md.

// CRM app request helpers.
//
// This used to hand-roll the request interceptor. It now defers to the shared
// client, which resolves the same class-context baseURL and carries the
// same-origin token gate, the FormData Content-Type handling and the
// sandboxed-iframe cookie rule. Keeping a private copy is how this app came to
// be missing the token gate in the first place.
//
// Two differences from the old copy, both deliberate: the shared client honours
// a caller-supplied baseURL (no call site passes one) and handles domain-entity
// routing, which this app previously did not.

import { createAppClient } from "@mochi/web";

export const crmsRequest = createAppClient({ appName: "crm" });
