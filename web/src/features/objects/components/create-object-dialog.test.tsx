// Tests for CreateObjectDialog component
import { describe, it, expect, vi, beforeEach } from "vitest";
import {
  render,
  screen,
  createMockCrmDetails,
  createMockField,
  createMockClass,
} from "@/test/test-utils";
import { CreateObjectDialog } from "./create-object-dialog";

// Mock crmsApi
vi.mock("@/api/crms", () => ({
  default: {
    listObjects: vi.fn().mockResolvedValue({ data: { objects: [] } }),
    listPeople: vi.fn().mockResolvedValue({ data: { people: [] } }),
    createObject: vi.fn().mockResolvedValue({
      data: { id: "new-1" },
    }),
    setValue: vi.fn().mockResolvedValue({ data: { success: true } }),
  },
}));

describe("CreateObjectDialog", () => {
  const defaultCrm = createMockCrmDetails({
    classes: [
      createMockClass({ id: "company", name: "Company", title: "name" }),
      createMockClass({ id: "contact", name: "Contact", title: "name" }),
    ],
    fields: {
      company: [
        createMockField({ id: "name", name: "Name", fieldtype: "text" }),
        createMockField({ id: "domain", name: "Domain", fieldtype: "text" }),
      ],
      contact: [
        createMockField({ id: "name", name: "Name", fieldtype: "text" }),
        createMockField({ id: "email", name: "Email", fieldtype: "text" }),
      ],
    },
    options: { company: {}, contact: {} },
    hierarchy: {
      company: [""],
      contact: ["company"],
    },
  });

  beforeEach(() => {
    vi.clearAllMocks();
  });

  it("should render when open", () => {
    render(
      <CreateObjectDialog
        open={true}
        onOpenChange={vi.fn()}
        crmId="abc123"
        crm={defaultCrm}
      />,
    );

    expect(screen.getByText("New")).toBeInTheDocument();
    expect(screen.getByText("Create")).toBeInTheDocument();
  });

  it("should show fields for selected class", () => {
    render(
      <CreateObjectDialog
        open={true}
        onOpenChange={vi.fn()}
        crmId="abc123"
        crm={defaultCrm}
      />,
    );

    // Company fields should be shown (first class selected by default)
    expect(screen.getByText("Name")).toBeInTheDocument();
    expect(screen.getByText("Domain")).toBeInTheDocument();
  });

  it("should filter classes when allowedClasses is provided", () => {
    render(
      <CreateObjectDialog
        open={true}
        onOpenChange={vi.fn()}
        crmId="abc123"
        crm={defaultCrm}
        allowedClasses={["contact"]}
      />,
    );

    // Should show contact fields
    expect(screen.getByText("Email")).toBeInTheDocument();
  });

  it("should show close button", () => {
    render(
      <CreateObjectDialog
        open={true}
        onOpenChange={vi.fn()}
        crmId="abc123"
        crm={defaultCrm}
      />,
    );

    expect(screen.getByTitle("Close")).toBeInTheDocument();
  });

  it("should not render when closed", () => {
    render(
      <CreateObjectDialog
        open={false}
        onOpenChange={vi.fn()}
        crmId="abc123"
        crm={defaultCrm}
      />,
    );

    expect(screen.queryByText("New")).not.toBeInTheDocument();
  });
});
