import { StrictMode } from "react";
import ReactDOM from "react-dom/client";
import { QueryClientProvider } from "@tanstack/react-query";
import { RouterProvider, createRouter } from "@tanstack/react-router";
import {
  CommandMenu,
  createQueryClient,
  SearchProvider,
  ThemeProvider,
  getAppPath,
  getRouterBasepath,
} from "@mochi/common";
// Generated Routes
import { routeTree } from "./routeTree.gen";
// Styles
import "./styles/index.css";

const queryClient = createQueryClient({
  onServerError: () => router.navigate({ to: "/500" }),
});

// Use app path as basepath, ignoring entity fingerprint.
// Routes use $crmId to handle entity fingerprints — including the fingerprint
// in the basepath would cause links to double it (e.g. /crms/<fp>/<fp>/...).
function getBasepath(): string {
  const appPath = getAppPath()
  if (appPath) return appPath + "/"
  return getRouterBasepath()
}

const router = createRouter({
  routeTree,
  context: { queryClient },
  basepath: getBasepath(),
  defaultPreload: "intent",
  defaultPreloadStaleTime: 0,
});

// Register the router instance for type safety
declare module "@tanstack/react-router" {
  interface Register {
    router: typeof router;
  }
}

// Render the app
const rootElement = document.getElementById("root")!;
if (!rootElement.innerHTML) {
  const root = ReactDOM.createRoot(rootElement);
  root.render(
    <StrictMode>
      <QueryClientProvider client={queryClient}>
        <ThemeProvider>
          <SearchProvider>
            <RouterProvider router={router} />
            <CommandMenu sidebarData={{ navGroups: [] }} />
          </SearchProvider>
        </ThemeProvider>
      </QueryClientProvider>
    </StrictMode>,
  );
}
