// Mochi CRM: Design editor page
// Copyright Alistair Cunningham 2026

import { createFileRoute, Navigate } from "@tanstack/react-router";
import { useCallback, useRef, useState } from "react";
import { useQuery, useQueryClient } from "@tanstack/react-query";
import {
  AlertDialog,
  AlertDialogAction,
  AlertDialogCancel,
  AlertDialogContent,
  AlertDialogDescription,
  AlertDialogFooter,
  AlertDialogHeader,
  AlertDialogTitle,
  Button,
  Dialog,
  DialogContent,
  DialogFooter,
  DialogHeader,
  DialogTitle,
  DropdownMenu,
  DropdownMenuContent,
  DropdownMenuItem,
  DropdownMenuTrigger,
  GeneralError,
  ListSkeleton,
  Main,
  PageHeader,
  toast,
  getErrorMessage,
  usePageTitle,
} from "@mochi/common";
import { Download, Loader2, MoreHorizontal, Settings2, Upload } from "lucide-react";
import crmsApi from "@/api/crms";
import type { CrmDetails } from "@/types";
import { canDesign } from "@/lib/access";
import { DesignEditor } from "@/features/editor";

export const Route = createFileRoute("/_authenticated/$crmId/design")({
  component: DesignPage,
  errorComponent: ({ error }) => <GeneralError error={error} />,
});

function DesignPage() {
  const { crmId } = Route.useParams();
  const queryClient = useQueryClient();

  const {
    data: crmData,
    isLoading,
    error,
  } = useQuery({
    queryKey: ["crm", crmId],
    queryFn: async () => {
      const response = await crmsApi.get(crmId);
      return response.data;
    },
  });

  const crm = crmData as CrmDetails | undefined;
  usePageTitle(crm ? `${crm.crm.name} - Design` : "Design");

  // Import dialog state
  const [importOpen, setImportOpen] = useState(false);
  const [confirmOpen, setConfirmOpen] = useState(false);
  const [importing, setImporting] = useState(false);
  const [pendingImport, setPendingImport] = useState<{
    data: Record<string, unknown>;
    template?: string;
    templateVersion?: number;
    label: string;
  } | null>(null);

  // Export handler
  const handleExport = useCallback(async () => {
    if (!crm) return;
    try {
      const response = await crmsApi.exportDesign(crmId);
      const json = JSON.stringify(response.data, null, 2);
      const blob = new Blob([json], { type: "application/json" });
      const url = URL.createObjectURL(blob);
      const a = document.createElement("a");
      a.href = url;
      a.download = `${crm.crm.name.toLowerCase().replace(/\s+/g, "-")}-design.json`;
      document.body.appendChild(a);
      a.click();
      document.body.removeChild(a);
      URL.revokeObjectURL(url);
    } catch (err) {
      toast.error(getErrorMessage(err, "Failed to export design"));
    }
  }, [crmId, crm]);

  // Import confirmation handler
  const handleConfirmImport = useCallback(async () => {
    if (!pendingImport) return;
    setImporting(true);
    try {
      await crmsApi.importDesign(
        crmId,
        pendingImport.data,
        pendingImport.template,
        pendingImport.templateVersion,
      );
      queryClient.invalidateQueries({ queryKey: ["crm", crmId] });
      toast.success("Design imported");
      setConfirmOpen(false);
      setImportOpen(false);
      setPendingImport(null);
    } catch (err) {
      toast.error(getErrorMessage(err, "Failed to import design"));
    } finally {
      setImporting(false);
    }
  }, [crmId, pendingImport, queryClient]);

  if (isLoading) {
    return (
      <Main>
        <ListSkeleton count={3} />
      </Main>
    );
  }

  if (error || !crm) {
    return <GeneralError error={error} />;
  }

  if (!canDesign(crm.crm.access)) {
    return <Navigate to="/$crmId" params={{ crmId }} />;
  }

  return (
    <>
      <PageHeader
        title={`${crm.crm.name} - Design`}
        icon={<Settings2 className="size-4 md:size-5" />}
        actions={
          <DropdownMenu>
            <DropdownMenuTrigger asChild>
              <Button variant="ghost" size="icon" className="size-8">
                <MoreHorizontal className="size-4" />
              </Button>
            </DropdownMenuTrigger>
            <DropdownMenuContent align="end">
              <DropdownMenuItem onClick={handleExport}>
                <Download className="size-4 mr-2" />
                Export design
              </DropdownMenuItem>
              <DropdownMenuItem onClick={() => setImportOpen(true)}>
                <Upload className="size-4 mr-2" />
                Import design
              </DropdownMenuItem>
            </DropdownMenuContent>
          </DropdownMenu>
        }
      />
      <Main fixed fluid className="flex-1 !py-0">
        <DesignEditor crmId={crmId} crm={crm} />
      </Main>

      {/* Import dialog */}
      <ImportDialog
        open={importOpen}
        onOpenChange={setImportOpen}
        onSelect={(data, template, templateVersion, label) => {
          setPendingImport({ data, template, templateVersion, label });
          setConfirmOpen(true);
        }}
      />

      {/* Confirm import dialog */}
      <AlertDialog open={confirmOpen} onOpenChange={setConfirmOpen}>
        <AlertDialogContent>
          <AlertDialogHeader>
            <AlertDialogTitle>Replace design?</AlertDialogTitle>
            <AlertDialogDescription>
              This will replace the current design with{" "}
              <strong>{pendingImport?.label}</strong>. All existing classes,
              fields, options, and views will be deleted. Existing objects will
              not be deleted but may no longer appear in views.
            </AlertDialogDescription>
          </AlertDialogHeader>
          <AlertDialogFooter>
            <AlertDialogCancel disabled={importing}>Cancel</AlertDialogCancel>
            <Button variant="ghost" onClick={handleExport} disabled={importing}>
              <Download className="size-4 mr-1.5" />
              Download backup first
            </Button>
            <AlertDialogAction onClick={handleConfirmImport} disabled={importing}>
              {importing && <Loader2 className="size-4 mr-1.5 animate-spin" />}
              Replace design
            </AlertDialogAction>
          </AlertDialogFooter>
        </AlertDialogContent>
      </AlertDialog>
    </>
  );
}

// Import dialog: upload JSON file
function ImportDialog({
  open,
  onOpenChange,
  onSelect,
}: {
  open: boolean;
  onOpenChange: (open: boolean) => void;
  onSelect: (
    data: Record<string, unknown>,
    template: string | undefined,
    templateVersion: number | undefined,
    label: string,
  ) => void;
}) {
  const fileInputRef = useRef<HTMLInputElement>(null);

  // Handle file upload
  const handleFileChange = (e: React.ChangeEvent<HTMLInputElement>) => {
    const file = e.target.files?.[0];
    if (!file) return;

    const reader = new FileReader();
    reader.onload = () => {
      try {
        const data = JSON.parse(reader.result as string);
        onSelect(data, undefined, undefined, file.name);
      } catch {
        toast.error("Invalid JSON file");
      }
    };
    reader.onerror = () => {
      toast.error("Failed to read file");
    };
    reader.readAsText(file);

    // Reset input so the same file can be selected again
    e.target.value = "";
  };

  return (
    <Dialog open={open} onOpenChange={onOpenChange}>
      <DialogContent>
        <DialogHeader>
          <DialogTitle>Import design</DialogTitle>
        </DialogHeader>

        <div className="space-y-4">
          <div className="space-y-2">
            <input
              ref={fileInputRef}
              type="file"
              accept=".json"
              onChange={handleFileChange}
              className="hidden"
            />
            <Button
              variant="outline"
              className="w-full"
              onClick={() => fileInputRef.current?.click()}
            >
              <Upload className="size-4 mr-1.5" />
              Upload .json file
            </Button>
          </div>
        </div>

        <DialogFooter>
          <Button variant="outline" onClick={() => onOpenChange(false)}>
            Cancel
          </Button>
        </DialogFooter>
      </DialogContent>
    </Dialog>
  );
}
