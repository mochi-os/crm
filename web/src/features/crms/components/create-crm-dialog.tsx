// Copyright © 2026 Mochi OÜ
// SPDX-License-Identifier: AGPL-3.0-only
// This file is part of Mochi, licensed under the GNU AGPL v3 with the
// Mochi Application Interface Exception - see license.txt and license-exception.md.

import { useEffect, useRef, useState } from "react";
import { Trans, useLingui } from '@lingui/react/macro'
import { plural } from '@lingui/core/macro'
import { useNavigate } from "@tanstack/react-router";
import {
  Button,
  ResponsiveDialog,
  ResponsiveDialogContent,
  ResponsiveDialogFooter,
  ResponsiveDialogHeader,
  ResponsiveDialogDescription,
  ResponsiveDialogTitle,
  ResponsiveDialogTrigger,
  Input,
  Label,
  Switch,
  toast,
  toastAction,
  getErrorMessage,
  Attachment,
  AttachmentMedia,
  AttachmentContent,
  AttachmentTitle,
  AttachmentAction,
  Tooltip,
  TooltipContent,
  TooltipTrigger,
} from "@mochi/web";
import { Plus, Upload, Users, X } from "lucide-react";
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
  const { t } = useLingui()
  const [isPending, setIsPending] = useState(false);
  const [name, setName] = useState("");
  const [allowSearch, setAllowSearch] = useState(true);
  const [importData, setImportData] = useState<Record<string, unknown> | null>(null);
  const [importFileName, setImportFileName] = useState("");
  const fileInputRef = useRef<HTMLInputElement>(null);
  const navigate = useNavigate();
  const refreshCrms = useCrmsStore((state) => state.refresh);

  // Reset state when dialog closes
  useEffect(() => {
    if (!open) {
      setName("");
      setAllowSearch(true);
      setImportData(null);
      setImportFileName("");
    }
  }, [open]);

  const handleSubmit = async (e: React.FormEvent) => {
    e.preventDefault();

    if (!name.trim()) {
      toast.error(t`Name is required`);
      return;
    }

    setIsPending(true);
    try {
      const response = await toastAction(
        crmsApi.create({
          name: name.trim(),
          privacy: allowSearch ? "public" : "private",
        }),
        {
          loading: t`Creating CRM...`,
          success: t`CRM created`,
          error: (e) => getErrorMessage(e, t`Failed to create CRM`),
        }
      );

      const fingerprint = response.data?.fingerprint;

      if (fingerprint && importData) {
        try {
          await toastAction(crmsApi.importData(fingerprint, importData), {
            loading: t`Importing data...`,
            success: (imported) => t`Data imported (${plural(imported.data?.objects ?? 0, { one: '# object', other: '# objects' })}, ${plural(imported.data?.comments ?? 0, { one: '# comment', other: '# comments' })}, ${plural(imported.data?.links ?? 0, { one: '# link', other: '# links' })})`,
            error: (e) => getErrorMessage(e, t`Failed to import data`),
          });
        } catch (e) {
          await crmsApi.delete(fingerprint).catch(() => {});
          throw e;
        }
      }

      await refreshCrms();

      onOpenChange?.(false);

      if (fingerprint) {
        void navigate({
          to: "/$crmId",
          params: { crmId: fingerprint },
        });
      } else {
        void navigate({ to: "/" });
      }
    } catch {
      // toast already shown
    } finally {
      setIsPending(false);
    }
  };

  const handleFileChange = (e: React.ChangeEvent<HTMLInputElement>) => {
    const file = e.target.files?.[0];
    if (!file) return;

    const reader = new FileReader();
    reader.onload = () => {
      try {
        const data = JSON.parse(reader.result as string);
        setImportData(data);
        setImportFileName(file.name);
      } catch {
        toast.error(t`Invalid JSON file`);
        setImportData(null);
        setImportFileName("");
      }
    };
    reader.onerror = () => {
      toast.error(t`Failed to read file`);
      setImportData(null);
      setImportFileName("");
    };
    reader.readAsText(file);
    e.target.value = "";
  };

  return (
    <ResponsiveDialog open={open} onOpenChange={onOpenChange}>
      {!hideTrigger && (
        <ResponsiveDialogTrigger asChild>
          <Button>
            <Plus className="me-2 size-4" />
            <Trans>Create CRM</Trans>
          </Button>
        </ResponsiveDialogTrigger>
      )}
      <ResponsiveDialogContent className="sm:max-w-md">
        <ResponsiveDialogHeader>
          <ResponsiveDialogTitle className="flex items-center gap-2">
            <div className="bg-primary/10 text-primary flex size-8 items-center justify-center rounded-lg">
              <Users className="size-4" />
            </div>
            <Trans>Create CRM</Trans>
          </ResponsiveDialogTitle>
          <ResponsiveDialogDescription className="sr-only"><Trans>Create a new CRM</Trans></ResponsiveDialogDescription>
        </ResponsiveDialogHeader>

        <form onSubmit={handleSubmit}>
          <div className="mt-4 space-y-4">
            <div className="space-y-2">
              <Label htmlFor="name"><Trans>Name</Trans></Label>
              <Input
                id="name"
                value={name}
                onChange={(e) => setName(e.target.value)}
                placeholder={t`Sales CRM`}
                autoFocus
              />
            </div>

            <div className="flex items-center justify-between rounded-lg border px-4 py-3">
              <Label htmlFor="allow-search" className="text-sm font-medium cursor-pointer">
                <Trans>Allow anyone to search for CRM</Trans>
              </Label>
              <Switch
                id="allow-search"
                checked={allowSearch}
                onCheckedChange={setAllowSearch}
              />
            </div>

            <div className="space-y-2">
              <Label><Trans>Import from backup (optional)</Trans></Label>
              <input
                ref={fileInputRef}
                type="file"
                accept=".json"
                onChange={handleFileChange}
                className="hidden"
              />
              <div className="flex gap-2">
                <Button
                  type="button"
                  variant="outline"
                  className="flex-1"
                  onClick={() => fileInputRef.current?.click()}
                >
                  <Upload className="size-4 me-1.5" />
                  <Trans>Upload .json file</Trans>
                </Button>
              </div>
              {importFileName && (
                <div className="mt-2">
                  <Attachment orientation="horizontal">
                    <AttachmentMedia>
                      <Upload className="size-4" />
                    </AttachmentMedia>
                    <AttachmentContent>
                      <AttachmentTitle>{importFileName}</AttachmentTitle>
                    </AttachmentContent>
                    <Tooltip>
                      <TooltipTrigger asChild>
                        <AttachmentAction
                          variant="ghost"
                          onClick={() => {
                            setImportData(null);
                            setImportFileName("");
                            if (fileInputRef.current) {
                              fileInputRef.current.value = "";
                            }
                          }}
                        >
                          <X className="size-4" />
                        </AttachmentAction>
                      </TooltipTrigger>
                      <TooltipContent><Trans>Remove</Trans></TooltipContent>
                    </Tooltip>
                  </Attachment>
                </div>
              )}
            </div>
          </div>

          <ResponsiveDialogFooter className="mt-6">
            <Button
              type="button"
              variant="outline"
              onClick={() => onOpenChange?.(false)}
            >
              <Trans>Cancel</Trans>
            </Button>
            <Button type="submit" disabled={isPending}>
              {isPending ? <Trans>Creating...</Trans> : <><Plus className="me-2 size-4" /><Trans>Create CRM</Trans></>}
            </Button>
          </ResponsiveDialogFooter>
        </form>
      </ResponsiveDialogContent>
    </ResponsiveDialog>
  );
}
