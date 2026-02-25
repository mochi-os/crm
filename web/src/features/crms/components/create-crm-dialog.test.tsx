// Tests for CreateCrmDialog component
import { describe, it, expect, vi, beforeEach } from "vitest";
import { render, screen, fireEvent, waitFor } from "@/test/test-utils";
import { CreateCrmDialog } from "./create-crm-dialog";

// Mock navigation
const mockNavigate = vi.fn();
vi.mock("@tanstack/react-router", () => ({
  useNavigate: () => mockNavigate,
}));

// Mock crmsApi
const mockCreate = vi.fn();
vi.mock("@/api/crms", () => ({
  default: {
    create: (...args: unknown[]) => mockCreate(...args),
  },
}));

// Mock store
vi.mock("@/stores/crms-store", () => ({
  useCrmsStore: (selector: (s: { refresh: () => Promise<void> }) => unknown) =>
    selector({ refresh: vi.fn() }),
}));

describe("CreateCrmDialog", () => {
  beforeEach(() => {
    vi.clearAllMocks();
  });

  it("should render dialog when open", () => {
    render(
      <CreateCrmDialog open={true} onOpenChange={vi.fn()} hideTrigger />,
    );

    expect(screen.getByLabelText("Name")).toBeInTheDocument();
    // "Create CRM" appears in both title and button
    expect(screen.getAllByText("Create CRM").length).toBeGreaterThanOrEqual(1);
  });

  it("should call create API on submit", async () => {
    mockCreate.mockResolvedValue({ data: { id: "123", fingerprint: "abc" } });

    render(
      <CreateCrmDialog open={true} onOpenChange={vi.fn()} hideTrigger />,
    );

    fireEvent.change(screen.getByLabelText("Name"), {
      target: { value: "Test CRM" },
    });

    fireEvent.click(screen.getByRole("button", { name: /Create CRM/i }));

    await waitFor(() => {
      expect(mockCreate).toHaveBeenCalledWith({
        name: "Test CRM",
        privacy: "public",
      });
    });
  });

  it("should show trigger button when hideTrigger is false", () => {
    render(
      <CreateCrmDialog open={false} onOpenChange={vi.fn()} />,
    );

    expect(screen.getByRole("button", { name: /Create CRM/i })).toBeInTheDocument();
  });

  it("should have privacy toggle defaulting to public", () => {
    render(
      <CreateCrmDialog open={true} onOpenChange={vi.fn()} hideTrigger />,
    );

    expect(screen.getByText("Allow anyone to search for CRM")).toBeInTheDocument();
  });
});
