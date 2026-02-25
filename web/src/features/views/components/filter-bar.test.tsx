// Tests for FilterBar component (shows active filter chips)
import { describe, it, expect, vi, beforeEach } from "vitest";
import { render, screen, fireEvent } from "@/test/test-utils";
import { FilterBar, type FilterState } from "./filter-bar";

describe("FilterBar", () => {
  const defaultFilters: FilterState = {
    search: "",
    watched: false,
  };
  const mockOnFilterChange = vi.fn();

  beforeEach(() => {
    vi.clearAllMocks();
  });

  it("should not render when no filters are active", () => {
    const { container } = render(
      <FilterBar
        filters={defaultFilters}
        onFilterChange={mockOnFilterChange}
      />,
    );

    expect(container.firstChild).toBeNull();
  });

  it("should show search filter chip when search is active", () => {
    render(
      <FilterBar
        filters={{ ...defaultFilters, search: "my search" }}
        onFilterChange={mockOnFilterChange}
      />,
    );

    expect(screen.getByText("Search:")).toBeInTheDocument();
    expect(screen.getByText("my search")).toBeInTheDocument();
  });

  it("should show watched filter chip", () => {
    render(
      <FilterBar
        filters={{ ...defaultFilters, watched: true }}
        onFilterChange={mockOnFilterChange}
      />,
    );

    expect(screen.getByText("Watched:")).toBeInTheDocument();
    expect(screen.getByText("On")).toBeInTheDocument();
  });

  it("should clear individual filter when X button is clicked", () => {
    render(
      <FilterBar
        filters={{ ...defaultFilters, search: "test" }}
        onFilterChange={mockOnFilterChange}
      />,
    );

    const clearButtons = screen.getAllByRole("button");
    fireEvent.click(clearButtons[0]);

    expect(mockOnFilterChange).toHaveBeenCalledWith({
      ...defaultFilters,
      search: "",
    });
  });

  it("should show clear all button when multiple filters are active", () => {
    render(
      <FilterBar
        filters={{ search: "test", watched: true }}
        onFilterChange={mockOnFilterChange}
      />,
    );

    expect(screen.getByText("Clear all")).toBeInTheDocument();
  });

  it("should not show clear all button when only one filter is active", () => {
    render(
      <FilterBar
        filters={{ ...defaultFilters, search: "test" }}
        onFilterChange={mockOnFilterChange}
      />,
    );

    expect(screen.queryByText("Clear all")).not.toBeInTheDocument();
  });

  it("should clear all filters when clear all button is clicked", () => {
    render(
      <FilterBar
        filters={{ search: "test", watched: true }}
        onFilterChange={mockOnFilterChange}
      />,
    );

    fireEvent.click(screen.getByText("Clear all"));

    expect(mockOnFilterChange).toHaveBeenCalledWith({
      search: "",
      watched: false,
    });
  });
});
