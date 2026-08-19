// Copyright © 2026 Mochisoft OÜ
// SPDX-License-Identifier: AGPL-3.0-only
// This file is part of Mochi, licensed under the GNU AGPL v3 with the
// Mochi Application Interface Exception - see license.txt and license-exception.md.

/* eslint-disable lingui/no-unlocalized-strings */
// The store behaviour is asserted once in @mochi/web, in
// src/lib/create-entity-list-store.test.ts. What is left here is this app's
// wiring: the list call it makes and the key it reads the rows out of.
import { describe, it, expect, vi, beforeEach } from "vitest";
import { useCrmsStore } from "./crms-store";

vi.mock("@/api/crms", () => ({
  default: {
    list: vi.fn(),
  },
}));

import crmsApi from "@/api/crms";

describe("useCrmsStore wiring", () => {
  beforeEach(() => {
    useCrmsStore.setState({ rows: [], isLoading: false, error: null });
    vi.clearAllMocks();
  });

  it("reads the rows out of the `crms` key this app's server answers under", async () => {
    vi.mocked(crmsApi.list).mockResolvedValue({
      data: {
        crms: [
          {
            id: "1",
            fingerprint: "abc",
            name: "Crm 1",
            description: "",
            owner: 1,
            ownername: "me",
            server: "",
            created: 0,
            updated: 0,
            populated: 1,
            access: "owner",
          },
        ],
      },
    });

    await useCrmsStore.getState().refresh();

    expect(crmsApi.list).toHaveBeenCalled();
    expect(useCrmsStore.getState().rows).toHaveLength(1);
  });

  it("falls back to this app's wording when a load fails without a message", async () => {
    vi.mocked(crmsApi.list).mockRejectedValue(new Error(""));

    await useCrmsStore.getState().refresh();

    expect(useCrmsStore.getState().error).toBe("Failed to load CRMs");
  });
});
