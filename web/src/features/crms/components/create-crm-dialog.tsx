import { useEffect, useRef, useState } from "react";
import { useNavigate } from "@tanstack/react-router";
import {
  Button,
  Dialog,
  DialogContent,
  DialogFooter,
  DialogHeader,
  DialogTitle,
  DialogTrigger,
  Input,
  Label,
  Switch,
  toast,
  getErrorMessage,
} from "@mochi/common";
import { Plus, Users } from "lucide-react";
import crmsApi from "@/api/crms";
import { useCrmsStore } from "@/stores/crms-store";

function nameToPrefix(name: string): string {
  return name
    .toLowerCase()
    .replace(/[^a-z0-9]+/g, "-")
    .replace(/^-|-$/g, "")
    .slice(0, 20);
}

interface CreateCrmDialogProps {
  open?: boolean;
  onOpenChange?: (open: boolean) => void;
  hideTrigger?: boolean;
}

export function CreateCrmDialog({
  open,
  onOpenChange,
  hideTrigger,
}: CreateCrmDialogProps) {
  const [isPending, setIsPending] = useState(false);
  const [name, setName] = useState("");
  const [prefix, setPrefix] = useState("");
  const [allowSearch, setAllowSearch] = useState(true);
  const prefixDirty = useRef(false);
  const navigate = useNavigate();
  const refreshCrms = useCrmsStore((state) => state.refresh);

  // Reset state when dialog closes
  useEffect(() => {
    if (!open) {
      setName("");
      setPrefix("");
      setAllowSearch(true);
      prefixDirty.current = false;
    }
  }, [open]);

  const handleSubmit = async (e: React.FormEvent) => {
    e.preventDefault();

    if (!name.trim()) {
      toast.error("Name is required");
      return;
    }

    setIsPending(true);
    try {
      const response = await crmsApi.create({
        name: name.trim(),
        prefix: prefix.trim().toLowerCase() || "crm",
        privacy: allowSearch ? "public" : "private",
      });

      const fingerprint = response.data?.fingerprint;
      await refreshCrms();

      toast.success("CRM created");
      onOpenChange?.(false);

      if (fingerprint) {
        void navigate({
          to: "/$crmId",
          params: { crmId: fingerprint },
        });
      } else {
        void navigate({ to: "/" });
      }
    } catch (err) {
      toast.error(getErrorMessage(err, "Failed to create CRM"));
    } finally {
      setIsPending(false);
    }
  };

  return (
    <Dialog open={open} onOpenChange={onOpenChange}>
      {!hideTrigger && (
        <DialogTrigger asChild>
          <Button>
            <Plus className="mr-2 size-4" />
            Create CRM
          </Button>
        </DialogTrigger>
      )}
      <DialogContent className="sm:max-w-md">
        <DialogHeader>
          <DialogTitle className="flex items-center gap-2">
            <div className="bg-primary/10 text-primary flex size-8 items-center justify-center rounded-lg">
              <Users className="size-4" />
            </div>
            Create CRM
          </DialogTitle>
        </DialogHeader>

        <form onSubmit={handleSubmit}>
          <div className="mt-4 space-y-4">
            <div className="space-y-2">
              <Label htmlFor="name">Name</Label>
              <Input
                id="name"
                value={name}
                onChange={(e) => {
                  setName(e.target.value);
                  if (!prefixDirty.current) {
                    setPrefix(nameToPrefix(e.target.value));
                  }
                }}
                placeholder="Sales CRM"
                autoFocus
              />
            </div>

            <div className="space-y-2">
              <Label htmlFor="prefix">Prefix</Label>
              <Input
                id="prefix"
                value={prefix}
                onChange={(e) => {
                  prefixDirty.current = true;
                  setPrefix(e.target.value.toLowerCase().replace(/[^a-z0-9-]/g, "").slice(0, 20));
                }}
                className="lowercase"
              />
              <p className="text-muted-foreground text-xs">
                Used for readable IDs like {prefix || "crm"}-1, {prefix || "crm"}-2
              </p>
            </div>

            <div className="flex items-center justify-between rounded-lg border px-4 py-3">
              <Label htmlFor="allow-search" className="text-sm font-medium cursor-pointer">
                Allow anyone to search for CRM
              </Label>
              <Switch
                id="allow-search"
                checked={allowSearch}
                onCheckedChange={setAllowSearch}
              />
            </div>
          </div>

          <DialogFooter className="mt-6">
            <Button
              type="button"
              variant="outline"
              onClick={() => onOpenChange?.(false)}
            >
              Cancel
            </Button>
            <Button type="submit" disabled={isPending}>
              {isPending ? "Creating..." : <><Plus className="mr-2 size-4" />Create CRM</>}
            </Button>
          </DialogFooter>
        </form>
      </DialogContent>
    </Dialog>
  );
}
