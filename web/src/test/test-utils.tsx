// Test utilities for React component testing
import React, { type ReactElement } from "react";
import { render, type RenderOptions } from "@testing-library/react";
import { QueryClient, QueryClientProvider } from "@tanstack/react-query";
import type {
  Crm,
  CrmDetails,
  CrmField,
  FieldOption,
  CrmView,
  CrmClass,
  CrmObject,
} from "@/types";

// Create a wrapper with all providers
function createTestQueryClient() {
  return new QueryClient({
    defaultOptions: {
      queries: {
        retry: false,
        gcTime: 0,
      },
      mutations: {
        retry: false,
      },
    },
  });
}

interface WrapperProps {
  children: React.ReactNode;
}

function AllProviders({ children }: WrapperProps) {
  const queryClient = createTestQueryClient();
  return (
    <QueryClientProvider client={queryClient}>{children}</QueryClientProvider>
  );
}

function customRender(
  ui: ReactElement,
  options?: Omit<RenderOptions, "wrapper">,
) {
  return render(ui, { wrapper: AllProviders, ...options });
}

// Re-export everything
export * from "@testing-library/react";
export { customRender as render };

// ============= Mock Data Factories =============

export function createMockCrm(overrides?: Partial<Crm>): Crm {
  return {
    id: "proj-1",
    fingerprint: "abc123def",
    name: "Test Crm",
    description: "A test crm",
    prefix: "TEST",
    counter: 10,
    owner: 1,
    ownername: "testuser",
    server: "local",
    created: Date.now(),
    updated: Date.now(),
    access: "owner",
    ...overrides,
  };
}

export function createMockField(overrides?: Partial<CrmField>): CrmField {
  return {
    id: "field-1",
    name: "Test Field",
    fieldtype: "text",
    flags: "",
    multi: 0,
    rank: 0,
    card: 0,
    position: "",
    rows: 0,
    ...overrides,
  };
}

export function createMockOption(overrides?: Partial<FieldOption>): FieldOption {
  return {
    id: "opt-1",
    name: "Test Option",
    colour: "#3b82f6",
    icon: "",
    rank: 0,
    ...overrides,
  };
}

export function createMockView(overrides?: Partial<CrmView>): CrmView {
  return {
    id: "view-1",
    name: "Board",
    viewtype: "board",
    filter: "",
    columns: "",
    rows: "",
    fields: "",
    sort: "",
    direction: "",
    classes: [],
    rank: 0,
    border: "",
    ...overrides,
  };
}

export function createMockClass(overrides?: Partial<CrmClass>): CrmClass {
  return {
    id: "task",
    name: "Task",
    rank: 0,
    requests: "",
    title: "title",
    ...overrides,
  };
}

export function createMockObject(
  overrides?: Partial<CrmObject>,
): CrmObject {
  return {
    id: "obj-1",
    crm: "proj-1",
    class: "task",
    number: 1,
    parent: "",
    rank: 1,
    created: Date.now(),
    updated: Date.now(),
    readable: "TEST-1",
    values: {
      title: "Test Task",
      status: "todo",
      priority: "medium",
    },
    ...overrides,
  };
}

export function createMockCrmDetails(
  overrides?: Partial<CrmDetails>,
): CrmDetails {
  const statusOptions: FieldOption[] = [
    createMockOption({ id: "todo", name: "To Do", colour: "#6b7280" }),
    createMockOption({ id: "in_progress", name: "In Progress", colour: "#f59e0b" }),
    createMockOption({ id: "done", name: "Done", colour: "#22c55e" }),
  ];

  const priorityOptions: FieldOption[] = [
    createMockOption({ id: "high", name: "High", colour: "#ef4444" }),
    createMockOption({ id: "medium", name: "Medium", colour: "#f59e0b" }),
    createMockOption({ id: "low", name: "Low", colour: "#22c55e" }),
  ];

  return {
    crm: createMockCrm(),
    classes: [createMockClass()],
    fields: {
      task: [
        createMockField({ id: "title", name: "Title", fieldtype: "text" }),
        createMockField({ id: "status", name: "Status", fieldtype: "select" }),
        createMockField({ id: "priority", name: "Priority", fieldtype: "select" }),
        createMockField({
          id: "description",
          name: "Description",
          fieldtype: "textarea",
        }),
      ],
    },
    options: {
      task: {
        status: statusOptions,
        priority: priorityOptions,
      },
    },
    views: [
      createMockView({ id: "board", name: "Board", viewtype: "board" }),
      createMockView({ id: "list", name: "List", viewtype: "list" }),
    ],
    hierarchy: {},
    ...overrides,
  };
}

// ============= Test Helpers =============

export function createMockObjects(count: number): CrmObject[] {
  return Array.from({ length: count }, (_, i) =>
    createMockObject({
      id: `obj-${i + 1}`,
      number: i + 1,
      readable: `TEST-${i + 1}`,
      values: {
        title: `Task ${i + 1}`,
        status: ["todo", "in_progress", "done"][i % 3],
        priority: ["high", "medium", "low"][i % 3],
      },
    }),
  );
}
