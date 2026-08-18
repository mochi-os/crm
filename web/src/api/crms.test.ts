// Copyright © 2026 Mochisoft OÜ
// SPDX-License-Identifier: AGPL-3.0-only
// This file is part of Mochi, licensed under the GNU AGPL v3 with the
// Mochi Application Interface Exception - see license.txt and license-exception.md.

/* eslint-disable lingui/no-unlocalized-strings */
// The CRM api is createEntityApi with nothing added, and the shared client is
// asserted once in @mochi/web (entity-api.test.ts, 56 tests over the 46 routes
// both apps call). What is left to check here is this app's own wiring: its
// request module, its endpoint table, and the resource key its unsubscribe
// sends.
import { describe, it, expect, vi, beforeEach } from "vitest";
import crmsApi from "./crms";
import { crmsRequest } from "./request";

vi.mock("./request", () => ({
  crmsRequest: {
    get: vi.fn(),
    post: vi.fn(),
  },
}));

describe("crmsApi wiring", () => {
  beforeEach(() => {
    vi.clearAllMocks();
  });

  it("reads through this app's request module and the shared route table", async () => {
    const mockResponse = { data: { crms: [{ id: "1", fingerprint: "abc", name: "Crm 1" }] } };
    vi.mocked(crmsRequest.get).mockResolvedValue(mockResponse);

    const result = await crmsApi.list();

    expect(crmsRequest.get).toHaveBeenCalledWith("-/list");
    expect(result).toEqual(mockResponse);
  });

  it("resolves an entity route against the shared table", async () => {
    vi.mocked(crmsRequest.get).mockResolvedValue({ data: {} });

    await crmsApi.get("crm123");

    expect(crmsRequest.get).toHaveBeenCalledWith("crm123/-/info");
  });

  it("names the resource `crm` when unsubscribing", async () => {
    vi.mocked(crmsRequest.post).mockResolvedValue({ data: { success: true } });

    await crmsApi.unsubscribe("crm123");

    expect(crmsRequest.post).toHaveBeenCalledWith("-/unsubscribe", {
      crm: "crm123",
    });
  });
});
