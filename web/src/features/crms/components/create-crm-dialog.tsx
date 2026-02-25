import { useEffect, useState } from "react";
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
  const [allowSearch, setAllowSearch] = useState(true);
  const navigate = useNavigate();
  const refreshCrms = useCrmsStore((state) => state.refresh);

  // Reset state when dialog closes
  useEffect(() => {
    if (!open) {
      setName("");
      setAllowSearch(true);
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
                onChange={(e) => setName(e.target.value)}
                placeholder="Sales CRM"
                autoFocus
              />
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
