// Mochi CRMs: WebSocket hook for real-time crm updates
// Copyright © 2026 Mochisoft OÜ
// SPDX-License-Identifier: AGPL-3.0-only
// This file is part of Mochi, licensed under the GNU AGPL v3 with the
// Mochi Application Interface Exception - see license.txt and license-exception.md.

import { useEntityWebsocket } from "@mochi/web";

// Subscribe to crm WebSocket events and invalidate relevant queries.
export function useCrmWebsocket(crmFingerprint?: string, onSync?: () => void) {
  useEntityWebsocket({
    entity: "crm",
    fingerprint: crmFingerprint,
    onSync,
  });
}
