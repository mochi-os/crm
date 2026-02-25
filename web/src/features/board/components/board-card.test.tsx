// Tests for BoardCard component
import { describe, it, expect, vi } from "vitest";
import {
  render,
  screen,
  fireEvent,
  createMockObject,
  createMockField,
  createMockClass,
  createMockOption,
} from "@/test/test-utils";
import { BoardCard } from "./board-card";

describe("BoardCard", () => {
  const titleField = createMockField({ id: "title", name: "Title", fieldtype: "text" });
  const defaultProps = {
    object: createMockObject(),
    fields: [titleField],
    options: {},
    classMap: { task: createMockClass() },
  };

  it("should render object title", () => {
    render(<BoardCard {...defaultProps} />);

    expect(screen.getByText("Test Task")).toBeInTheDocument();
  });

  it("should use Untitled as title when title is missing", () => {
    const objectWithoutTitle = createMockObject({
      values: { status: "todo" },
    });

    render(<BoardCard {...defaultProps} object={objectWithoutTitle} />);

    // The title should fall back to "Untitled"
    const elements = screen.getAllByText("Untitled");
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

  it("should apply option colour as a dot next to enumerated badge", () => {
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

    const { container } = render(
      <BoardCard
        {...defaultProps}
        object={objectWithCategory}
        fields={[titleField, categoryField]}
        options={{ category: categoryOptions }}
      />,
    );

    expect(screen.getByText("Bug")).toBeInTheDocument();
    // Colour is rendered as a dot (rounded-full span) next to the option name
    const dot = container.querySelector("span.rounded-full");
    expect(dot).toBeInTheDocument();
    expect(dot).toHaveStyle({ backgroundColor: "#6b7280" });
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

  it("should apply border color from borderField option", () => {
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
        borderField="priority"
      />,
    );

    // Border color is applied via inline style on the card
    const card = container.firstChild as HTMLElement;
    expect(card).toHaveStyle({ borderColor: "#ef4444" });
  });

  it("should render nested children when provided", () => {
    const childObject = createMockObject({
      id: "child-1",
      values: { title: "Child Task" },
    });

    render(
      <BoardCard
        {...defaultProps}
        children={[childObject]}
        childrenByParent={{}}
      />,
    );

    // Child should be rendered nested inside the parent card
    expect(screen.getByText("Child Task")).toBeInTheDocument();
  });
});
