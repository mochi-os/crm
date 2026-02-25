// Tests for BoardCard component
import { describe, it, expect, vi } from "vitest";
import {
  render,
  screen,
  fireEvent,
  createMockObject,
  createMockField,
  createMockOption,
} from "@/test/test-utils";
import { BoardCard } from "./board-card";

describe("BoardCard", () => {
  const defaultProps = {
    object: createMockObject(),
    fields: [],
    options: {},
    prefix: "TEST",
  };

  it("should render object title", () => {
    render(<BoardCard {...defaultProps} />);

    expect(screen.getByText("Test Task")).toBeInTheDocument();
  });

  it("should use prefix-number as title when title is missing", () => {
    const objectWithoutTitle = createMockObject({
      values: { status: "todo" },
    });

    render(<BoardCard {...defaultProps} object={objectWithoutTitle} />);

    // The title should fall back to prefix-number
    const elements = screen.getAllByText("TEST-1");
    expect(elements.length).toBeGreaterThanOrEqual(1);
  });

  it("should call onClick when card is clicked", () => {
    const onClick = vi.fn();

    render(<BoardCard {...defaultProps} onClick={onClick} />);

    fireEvent.click(screen.getByText("Test Task"));

    expect(onClick).toHaveBeenCalledTimes(1);
  });

  it("should be draggable", () => {
    render(<BoardCard {...defaultProps} />);

    const card = screen.getByText("Test Task").closest("div[draggable]");
    expect(card).toHaveAttribute("draggable", "true");
  });

  it("should set drag data on drag start", () => {
    render(<BoardCard {...defaultProps} />);

    const card = screen.getByText("Test Task").closest("div[draggable]");
    const setData = vi.fn();
    const dataTransfer = {
      setData,
      effectAllowed: "",
    };

    fireEvent.dragStart(card!, { dataTransfer });

    expect(setData).toHaveBeenCalledWith("text/plain", "obj-1");
  });

  it("should render enumerated card fields (excluding status/priority/title)", () => {
    // Create a custom enumerated field that isn't status or priority
    const categoryField = createMockField({
      id: "category",
      name: "Category",
      fieldtype: "enumerated",
      card: 1,
    });

    const categoryOptions = [
      createMockOption({ id: "bug", name: "Bug", colour: "#ef4444" }),
      createMockOption({ id: "feature", name: "Feature", colour: "#22c55e" }),
    ];

    const objectWithCategory = createMockObject({
      values: {
        title: "Test Task",
        status: "todo",
        category: "bug",
      },
    });

    render(
      <BoardCard
        {...defaultProps}
        object={objectWithCategory}
        fields={[categoryField]}
        options={{ category: categoryOptions }}
      />,
    );

    expect(screen.getByText("Bug")).toBeInTheDocument();
  });

  it("should not render fields when card=0", () => {
    const descField = createMockField({
      id: "description",
      name: "Description",
      fieldtype: "textarea",
      card: 0,
    });

    const objectWithDesc = createMockObject({
      values: {
        title: "Test Task",
        description: "This is a description",
        status: "todo",
      },
    });

    render(
      <BoardCard
        {...defaultProps}
        object={objectWithDesc}
        fields={[descField]}
      />,
    );

    // Description is shown separately from card fields
    // But card=0 fields shouldn't appear in the tags section
    expect(screen.queryByText("Description:")).not.toBeInTheDocument();
  });

  it("should not render card field if value is empty", () => {
    const categoryField = createMockField({
      id: "category",
      name: "Category",
      fieldtype: "enumerated",
      card: 1,
    });

    const categoryOptions = [
      createMockOption({ id: "bug", name: "Bug", colour: "#ef4444" }),
    ];

    const objectWithoutCategory = createMockObject({
      values: {
        title: "Test Task",
        status: "todo",
      },
    });

    render(
      <BoardCard
        {...defaultProps}
        object={objectWithoutCategory}
        fields={[categoryField]}
        options={{ category: categoryOptions }}
      />,
    );

    expect(screen.queryByText("Bug")).not.toBeInTheDocument();
  });

  it("should apply option colour to enumerated badge", () => {
    const categoryField = createMockField({
      id: "category",
      name: "Category",
      fieldtype: "enumerated",
      card: 1,
    });

    const categoryOptions = [
      createMockOption({ id: "bug", name: "Bug", colour: "#6b7280" }),
    ];

    const objectWithCategory = createMockObject({
      values: {
        title: "Test Task",
        status: "todo",
        category: "bug",
      },
    });

    render(
      <BoardCard
        {...defaultProps}
        object={objectWithCategory}
        fields={[categoryField]}
        options={{ category: categoryOptions }}
      />,
    );

    const badge = screen.getByText("Bug");
    expect(badge).toHaveStyle({ color: "#6b7280" });
  });

  it("should render multiple card fields", () => {
    const categoryField = createMockField({
      id: "category",
      name: "Category",
      fieldtype: "enumerated",
      card: 1,
    });

    const labelField = createMockField({
      id: "label",
      name: "Label",
      fieldtype: "enumerated",
      card: 1,
    });

    const categoryOptions = [
      createMockOption({ id: "bug", name: "Bug", colour: "#ef4444" }),
    ];

    const labelOptions = [
      createMockOption({ id: "urgent", name: "Urgent", colour: "#6b7280" }),
    ];

    const object = createMockObject({
      values: {
        title: "Test Task",
        status: "todo",
        category: "bug",
        label: "urgent",
      },
    });

    render(
      <BoardCard
        {...defaultProps}
        object={object}
        fields={[categoryField, labelField]}
        options={{
          category: categoryOptions,
          label: labelOptions,
        }}
      />,
    );

    expect(screen.getByText("Bug")).toBeInTheDocument();
    expect(screen.getByText("Urgent")).toBeInTheDocument();
  });

  it("should show priority color strip when priority is set", () => {
    const object = createMockObject({
      values: {
        title: "Test Task",
        priority: "high",
      },
    });

    const priorityOptions = [
      createMockOption({ id: "high", name: "High", colour: "#ef4444" }),
    ];

    const { container } = render(
      <BoardCard
        {...defaultProps}
        object={object}
        options={{ priority: priorityOptions }}
      />,
    );

    // Look for the priority strip element
    const strip = container.querySelector(".w-1.rounded-r-full");
    expect(strip).toBeInTheDocument();
    expect(strip).toHaveStyle({ backgroundColor: "rgb(239, 68, 68)" });
  });

  it("should show parent icon when parent is set", () => {
    const parentObject = createMockObject({
      id: "parent-1",
      class: "epic",
      number: 5,
      values: { title: "Parent Epic" },
    });

    const childObject = createMockObject({
      parent: "parent-1",
      values: { title: "Child Task" },
    });

    const objectMap = { "parent-1": parentObject };

    const { container } = render(
      <BoardCard
        {...defaultProps}
        object={childObject}
        objectMap={objectMap}
      />,
    );

    // Parent indicator icon should be rendered
    expect(container.querySelector("svg")).toBeInTheDocument();
  });
});
