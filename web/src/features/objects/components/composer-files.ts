// Mochi CRMs: Staged composer file helpers
// Copyright © 2026 Mochisoft OÜ
// SPDX-License-Identifier: AGPL-3.0-only
// This file is part of Mochi, licensed under the GNU AGPL v3 with the
// Mochi Application Interface Exception - see license.txt and license-exception.md.

import { pendingFileKey } from "@mochi/web";

/**
 * Appends only the files that are not already staged.
 *
 * Picking or dropping the same file twice yields the same `pendingFileKey`,
 * which collides as a React key and uploads the file twice. Returns `prev`
 * untouched when every incoming file was a duplicate, so the preview object
 * URLs keyed off the array reference are not rebuilt for nothing.
 */
export function mergePendingFiles(prev: File[], incoming: File[]): File[] {
  const seen = new Set(prev.map(pendingFileKey));
  const added = incoming.filter((file) => {
    const key = pendingFileKey(file);
    if (seen.has(key)) return false;
    seen.add(key);
    return true;
  });
  return added.length > 0 ? [...prev, ...added] : prev;
}
