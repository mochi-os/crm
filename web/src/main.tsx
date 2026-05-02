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
  I18nProvider,
  type Catalogs,
} from "@mochi/web";
// Generated Routes
import { routeTree } from "./routeTree.gen";
// Styles
import "./styles/index.css";

// Lingui catalogs bundled by @lingui/vite-plugin (compiled from
// src/locales/<lang>/messages.po on the fly).
const catalogs: Catalogs = {
  en: () => import("./locales/en/messages.po"),
  "en-us": () => import("./locales/en-US/messages.po"),
  fr: () => import("./locales/fr/messages.po"),
  ja: () => import("./locales/ja/messages.po"),
  ar: () => import("./locales/ar/messages.po"),
  "en-x-pseudo": () => import("./locales/en-x-pseudo/messages.po"),
};

const queryClient = createQueryClient();

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
        <I18nProvider catalogs={catalogs}>
          <ThemeProvider>
            <SearchProvider>
              <RouterProvider router={router} />
              <CommandMenu sidebarData={{ navGroups: [] }} />
            </SearchProvider>
          </ThemeProvider>

        </I18nProvider>
      </QueryClientProvider>
    </StrictMode>,
  );
}
