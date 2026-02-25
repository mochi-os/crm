// Tests for the crms store
import { describe, it, expect, vi, beforeEach } from "vitest";
import { useCrmsStore } from "./crms-store";
import type { Crm } from "@/types";

// Mock the API module
vi.mock("@/api/crms", () => ({
  default: {
    list: vi.fn(),
  },
}));

import crmsApi from "@/api/crms";

describe("useCrmsStore", () => {
  beforeEach(() => {
    // Reset store state between tests
    useCrmsStore.setState({
      crms: [],
      isLoading: false,
      error: null,
    });
    vi.clearAllMocks();
  });

  it("should have correct initial state", () => {
    const state = useCrmsStore.getState();

    expect(state.crms).toEqual([]);
    expect(state.isLoading).toBe(false);
    expect(state.error).toBeNull();
  });

  it("should set loading state when refreshing", async () => {
    vi.mocked(crmsApi.list).mockResolvedValue({
      data: { crms: [] },
    });

    const refreshPromise = useCrmsStore.getState().refresh();

    // Should be loading immediately
    expect(useCrmsStore.getState().isLoading).toBe(true);

    await refreshPromise;

    // Should not be loading after completion
    expect(useCrmsStore.getState().isLoading).toBe(false);
  });

  it("should load crms successfully", async () => {
    const mockCrms: Crm[] = [
      {
        id: "1",
        fingerprint: "abc123",
        name: "Crm 1",
        description: "",
        prefix: "P1",
        counter: 1,
        owner: 1,
        ownername: "testuser",
        server: "local",
        created: Date.now(),
        updated: Date.now(),
        access: "owner",
      },
      {
        id: "2",
        fingerprint: "def456",
        name: "Crm 2",
        description: "Test crm",
        prefix: "P2",
        counter: 5,
        owner: 1,
        ownername: "testuser",
        server: "local",
        created: Date.now(),
        updated: Date.now(),
        access: "owner",
      },
    ];

    vi.mocked(crmsApi.list).mockResolvedValue({
      data: { crms: mockCrms },
    });

    await useCrmsStore.getState().refresh();

    const state = useCrmsStore.getState();
    expect(state.crms).toEqual(mockCrms);
    expect(state.isLoading).toBe(false);
    expect(state.error).toBeNull();
  });

  it("should handle API errors", async () => {
    vi.mocked(crmsApi.list).mockRejectedValue(new Error("Network error"));

    await useCrmsStore.getState().refresh();

    const state = useCrmsStore.getState();
    expect(state.crms).toEqual([]);
    expect(state.isLoading).toBe(false);
    expect(state.error).toBe("Network error");
  });

  it("should handle empty crms list", async () => {
    vi.mocked(crmsApi.list).mockResolvedValue({
      data: { crms: [] },
    });

    await useCrmsStore.getState().refresh();

    const state = useCrmsStore.getState();
    expect(state.crms).toEqual([]);
    expect(state.error).toBeNull();
  });

  it("should handle missing crms array gracefully", async () => {
    vi.mocked(crmsApi.list).mockResolvedValue({
      data: { crms: undefined as unknown as [] },
    });

    await useCrmsStore.getState().refresh();

    const state = useCrmsStore.getState();
    expect(state.crms).toEqual([]);
    expect(state.error).toBeNull();
  });
});
