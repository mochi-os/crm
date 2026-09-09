// Copyright © 2026 Mochisoft OÜ
// SPDX-License-Identifier: AGPL-3.0-only
// This file is part of Mochi, licensed under the GNU AGPL v3 with the
// Mochi Application Interface Exception - see license.txt and license-exception.md.

/* eslint-disable lingui/no-unlocalized-strings */
// Where a render error lands. TanStack only wraps a match in a CatchBoundary
// when the route resolves an errorComponent (route.options.errorComponent ??
// router.options.defaultErrorComponent), so before the default was set the only
// boundary in the tree was __root's and a crash in the page body took the
// sidebar down with it. These two cases pin that difference.

import { readFile } from "node:fs/promises";
import path from "node:path";
import { describe, it, expect, vi, afterEach } from "vitest";
import {
  createMemoryHistory,
  createRootRoute,
  createRoute,
  createRouter,
  Outlet,
  RouterProvider,
} from "@tanstack/react-router";
import { GeneralError } from "@mochi/web";
import { render, screen, waitFor } from "@/test/test-utils";

const CRASH_MESSAGE = "Cannot read properties of undefined (reading 'name')";

// The shape of the real tree: __root carries an errorComponent, the
// _authenticated layout renders the sidebar around an Outlet, and the page sits
// under it. Only the router option under test differs between the two cases.
function buildRouter(defaultErrorComponent?: typeof GeneralError) {
  const rootRoute = createRootRoute({
    component: Outlet,
    errorComponent: GeneralError,
  });

  const layoutRoute = createRoute({
    getParentRoute: () => rootRoute,
    id: "_authenticated",
    component: () => (
      <>
        <nav>All CRMs</nav>
        <Outlet />
      </>
    ),
  });

  const objectRoute = createRoute({
    getParentRoute: () => layoutRoute,
    path: "/$crmId/$objectId",
    component: function ObjectPage(): never {
      throw new TypeError(CRASH_MESSAGE);
    },
  });

  return createRouter({
    routeTree: rootRoute.addChildren([layoutRoute.addChildren([objectRoute])]),
    history: createMemoryHistory({ initialEntries: ["/crm-1/obj-1"] }),
    defaultPreload: false,
    defaultErrorComponent,
  });
}

describe("route error containment", () => {
  // React reports every caught render error on console.error. Both cases throw
  // on purpose, so the noise is silenced rather than left in the run output.
  const consoleError = vi
    .spyOn(console, "error")
    .mockImplementation(() => undefined);

  afterEach(() => {
    consoleError.mockClear();
  });

  it("keeps the sidebar mounted when the page body throws", async () => {
    render(<RouterProvider router={buildRouter(GeneralError)} />);

    await waitFor(() => {
      expect(screen.getByText(CRASH_MESSAGE)).toBeInTheDocument();
    });

    // The whole point: the CRM list is still there to navigate away with.
    expect(screen.getByText("All CRMs")).toBeInTheDocument();
    expect(screen.getByRole("button", { name: "Try again" })).toBeInTheDocument();
  });

  it("loses the sidebar when no route resolves an errorComponent", async () => {
    render(<RouterProvider router={buildRouter(undefined)} />);

    await waitFor(() => {
      expect(screen.getByText(CRASH_MESSAGE)).toBeInTheDocument();
    });

    // Caught at __root instead, which renders in place of the whole tree.
    expect(screen.queryByText("All CRMs")).not.toBeInTheDocument();
  });

  // The behaviour above only holds while the router actually sets the default.
  // main.tsx renders on import, so it is read rather than imported. Vitest runs
  // from the package root, so the path is resolved from there.
  it("sets the default on the app's own router", async () => {
    const source = await readFile(
      path.resolve(process.cwd(), "src/main.tsx"),
      "utf8",
    );
    expect(source).toMatch(/defaultErrorComponent:\s*GeneralError/);
  });
});
