// Copyright © 2026 Mochisoft OÜ
// SPDX-License-Identifier: AGPL-3.0-only
// This file is part of Mochi, licensed under the GNU AGPL v3 with the
// Mochi Application Interface Exception - see license.txt and license-exception.md.

/* eslint-disable lingui/no-unlocalized-strings */
// The routes themselves are asserted once in @mochi/web, in
// lib/entity-endpoints.test.ts. The CRM server exposes exactly that table and
// nothing more, so all this file has left to check is that the binding hands
// the shared table through unchanged.
import { describe, it, expect } from "vitest";
import { entityEndpoints } from "@mochi/web";
import endpoints from "./endpoints";

describe("endpoints.crms", () => {
  it("is the shared entity table, unchanged", () => {
    expect(endpoints.crms).toBe(entityEndpoints);
  });

  it("adds no endpoint of its own", () => {
    expect(Object.keys(endpoints.crms).sort()).toEqual(
      Object.keys(entityEndpoints).sort(),
    );
  });
});
