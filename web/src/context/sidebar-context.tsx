import { createContext, useContext, useState, type ReactNode } from "react";

interface SidebarContextType {
  createDialogOpen: boolean;
  openCreateDialog: () => void;
  closeCreateDialog: () => void;
}

const SidebarContext = createContext<SidebarContextType | null>(null);

export function SidebarProvider({ children }: { children: ReactNode }) {
  const [createDialogOpen, setCreateDialogOpen] = useState(false);

  const openCreateDialog = () => setCreateDialogOpen(true);
  const closeCreateDialog = () => setCreateDialogOpen(false);

  return (
    <SidebarContext.Provider
      value={{
        createDialogOpen,
        openCreateDialog,
        closeCreateDialog,
      }}
    >
      {children}
    </SidebarContext.Provider>
  );
}

export function useSidebarContext() {
  const context = useContext(SidebarContext);
  if (!context) {
    throw new Error("useSidebarContext must be used within a SidebarProvider");
  }
  return context;
}
