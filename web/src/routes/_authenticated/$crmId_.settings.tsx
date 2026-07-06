// Mochi CRM: CRM settings page
// Copyright © 2026 Mochi OÜ
// SPDX-License-Identifier: AGPL-3.0-only
// This file is part of Mochi, licensed under the GNU AGPL v3 with the
// Mochi Application Interface Exception - see license.txt and license-exception.md.

import { createFileRoute, useNavigate } from "@tanstack/react-router";
import { Trans, useLingui } from '@lingui/react/macro'
import { useCallback, useMemo, useRef, useState } from "react";
import { useQuery, useQueryClient } from "@tanstack/react-query";
import {
  Button,
  ConfirmDialog,
  ResponsiveDialog,
  ResponsiveDialogContent,
  ResponsiveDialogHeader,
  ResponsiveDialogTitle,
  ResponsiveDialogDescription,
  ResponsiveDialogFooter,
  PageHeader,
  Main,
  Tabs,
  TabsList,
  TabsTrigger,
  usePageTitle,
  EmptyState,
  Skeleton,
  Section,
  FieldRow,
  EditableFieldRow,
  DataChip,
  toastAction,
  getErrorMessage,
  extractStatus,
  AccessDialog,
  AccessList,
  GeneralError,
  toast,
  type AccessRule,
  type AccessLevel,
} from "@mochi/web";
import {
  Users,
  Settings,
  Shield,
  Trash2,
  Plus,
  FileDown,
  FileUp,
  Upload,
  Loader2,
} from "lucide-react";
import crmsApi from "@/api/crms";
import type { CrmDetails } from "@/types";
import { canDesign } from "@/lib/access";
import { useCrmsStore } from "@/stores/crms-store";

// Characters disallowed in CRM names (matches backend validation)
const DISALLOWED_NAME_CHARS = /[<>\r\n]/;


type TabId = "general" | "access";

type SettingsSearch = {
  tab?: TabId;
};

export const Route = createFileRoute("/_authenticated/$crmId_/settings")({
  validateSearch: (search: Record<string, unknown>): SettingsSearch => ({
    tab:
      search.tab === "general" || search.tab === "access"
        ? search.tab
        : undefined,
  }),
  component: CrmSettingsPage,
});

interface Tab {
  id: TabId;
  label: string;
  icon: React.ReactNode;
}

function CrmSettingsPage() {
  const { t } = useLingui()
  const { crmId } = Route.useParams();
  const navigate = useNavigate();
  const navigateSettings = Route.useNavigate();
  const { tab } = Route.useSearch();
  const activeTab = tab ?? "general";
  const queryClient = useQueryClient();
  const refreshSidebar = useCrmsStore((state) => state.refresh);
  const goBackToCrm = () => navigate({ to: "/$crmId", params: { crmId } });
  const tabs: Tab[] = [
    { id: "general", label: t`Settings`, icon: <Settings className="h-4 w-4" /> },
    { id: "access", label: t`Access`, icon: <Shield className="h-4 w-4" /> },
  ];

  const setActiveTab = (newTab: TabId) => {
    void navigateSettings({ search: { tab: newTab }, replace: true });
  };

  const [isDeleting, setIsDeleting] = useState(false);
  const [showDeleteDialog, setShowDeleteDialog] = useState(false);

  const {
    data: crmData,
    isLoading,
    error,
    refetch: refetchCrm,
  } = useQuery({
    queryKey: ["crm", crmId],
    queryFn: async () => {
      const response = await crmsApi.get(crmId);
      return response.data;
    },
    retry: false,
    refetchOnWindowFocus: false,
  });

  const crm = crmData as CrmDetails | undefined;
  const isOwner = crm?.crm.owner === 1;
  const crmStatus = extractStatus(error);
  const crmLookupError =
    error && crmStatus !== 403 && crmStatus !== 404
      ? error
      : null;
  const crmNotFound =
    !crm && (crmStatus === 403 || crmStatus === 404 || (!isLoading && !error));

  usePageTitle(
    crm ? t`${crm.crm.name} settings` : t`CRM settings`
  );

  const handleDelete = useCallback(async () => {
    if (!crm || !isOwner || isDeleting) return;

    setIsDeleting(true);
    try {
      await toastAction(crmsApi.delete(crm.crm.id), {
        loading: t`Deleting CRM...`,
        success: t`CRM deleted`,
        error: (e) => getErrorMessage(e, t`Failed to delete CRM`),
      });
      void refreshSidebar();
      void navigate({ to: "/" });
    } catch {
      // toast already shown
    } finally {
      setIsDeleting(false);
    }
  }, [crm, isOwner, isDeleting, refreshSidebar, navigate, t]);

  const handleUpdate = useCallback(
    async (updates: {
      name?: string;
      description?: string;
    }) => {
      if (!crm || !isOwner) return;

      try {
        await toastAction(crmsApi.update(crm.crm.id, updates), {
          loading: t`Saving...`,
          success: t`CRM updated`,
          error: (e) => getErrorMessage(e, t`Failed to update crm`),
        });
        void refreshSidebar();
        queryClient.invalidateQueries({ queryKey: ["crm", crmId] });
      } catch (err) {
        throw err;
      }
    },
    [crm, isOwner, refreshSidebar, queryClient, crmId, t]
  );

  if (isLoading) {
    return (
      <>
        <PageHeader
          title={t`Settings`}
          icon={<Settings className="size-4 md:size-5" />}
          back={{ label: t`Back to CRM`, onFallback: goBackToCrm }}
        />
        <Main className="space-y-6">
          <div className="flex gap-1 border-b">
            <div className="flex items-center gap-2 px-4 py-2 border-b-2 border-transparent">
              <Skeleton className="h-4 w-4" />
              <Skeleton className="h-4 w-16" />
            </div>
          </div>
          <div className="pt-2">
            <Skeleton className="h-64 w-full rounded-xl" />
          </div>
        </Main>
      </>
    );
  }

  if (!crm) {
    return (
      <>
        <PageHeader
          title={t`Settings`}
          icon={<Settings className="size-4 md:size-5" />}
          back={{ label: t`Back to CRM`, onFallback: goBackToCrm }}
        />
        <Main>
          {crmLookupError ? (
            <GeneralError
              error={crmLookupError}
              minimal
              mode="inline"
              reset={() => {
                void refetchCrm();
              }}
            />
          ) : (
            <EmptyState
              icon={Users}
              title={crmNotFound ? t`CRM not found` : t`CRM unavailable`}
              description={
                crmNotFound
                  ? t`This CRM may have been deleted or you don't have access to it.` : t`This CRM could not be loaded right now.`
              }
            />
          )}
        </Main>
      </>
    );
  }

  return (
    <>
      <PageHeader
        title={t`${crm.crm.name} settings`}
        icon={<Settings className="size-4 md:size-5" />}
        back={{ label: t`Back to CRM`, onFallback: goBackToCrm }}
      />
      <Main className="space-y-6">
        {/* Tabs - only show for owners */}
        {isOwner && (
          <Tabs
            variant="underline"
            value={activeTab}
            onValueChange={(value) => setActiveTab(value as TabId)}
          >
            <TabsList>
              {tabs.map((t) => (
                <TabsTrigger key={t.id} value={t.id} className="gap-2">
                  {t.icon}
                  {t.label}
                </TabsTrigger>
              ))}
            </TabsList>
          </Tabs>
        )}

        {/* Tab content */}
        <div className="pt-2">
          {activeTab === "general" && (
            <GeneralTab
              crm={crm}
              isOwner={isOwner}
              isDeleting={isDeleting}
              showDeleteDialog={showDeleteDialog}
              setShowDeleteDialog={setShowDeleteDialog}
              onDelete={handleDelete}
              onUpdate={handleUpdate}
            />
          )}
          {activeTab === "access" && isOwner && (
            <AccessTab crmId={crm.crm.id} />
          )}
        </div>
      </Main>
    </>
  );
}

interface GeneralTabProps {
  crm: CrmDetails;
  isOwner: boolean;
  isDeleting: boolean;
  showDeleteDialog: boolean;
  setShowDeleteDialog: (show: boolean) => void;
  onDelete: () => void;
  onUpdate: (updates: {
    name?: string;
    description?: string;
  }) => Promise<void>;
}

function GeneralTab({
  crm,
  isOwner,
  isDeleting,
  showDeleteDialog,
  setShowDeleteDialog,
  onDelete,
  onUpdate,
}: GeneralTabProps) {
  const { t } = useLingui();
  const queryClient = useQueryClient();
  const crmId = crm.crm.id;

  // Data import dialog state
  const [dataImportOpen, setDataImportOpen] = useState(false);
  const [dataConfirmOpen, setDataConfirmOpen] = useState(false);
  const [dataImporting, setDataImporting] = useState(false);
  const [pendingDataImport, setPendingDataImport] = useState<{
    data: Record<string, unknown>;
    label: string;
  } | null>(null);

  // Data Export handler
  const handleDataExport = useCallback(async () => {
    try {
      const response = await crmsApi.exportData(crmId);
      const json = JSON.stringify(response.data, null, 2);
      const blob = new Blob([json], { type: "application/json" });
      const url = URL.createObjectURL(blob);
      const a = document.createElement("a");
      a.href = url;
      a.download = `${crm.crm.name.toLowerCase().replace(/\s+/g, "-")}-data.json`;
      document.body.appendChild(a);
      a.click();
      document.body.removeChild(a);
      URL.revokeObjectURL(url);
    } catch (err) {
      toast.error(getErrorMessage(err, t`Failed to export data`));
    }
  }, [crmId, crm, t]);

  // Data Import confirmation handler
  const handleConfirmDataImport = useCallback(async () => {
    if (!pendingDataImport) return;
    setDataImporting(true);
    try {
      const response = await crmsApi.importData(
        crmId,
        pendingDataImport.data,
      );
      queryClient.invalidateQueries({ queryKey: ["crm", crmId] });
      toast.success(t`Data imported (${response.data?.objects ?? 0} objects, ${response.data?.comments ?? 0} comments, ${response.data?.links ?? 0} links)`);
      setDataConfirmOpen(false);
      setDataImportOpen(false);
      setPendingDataImport(null);
    } catch (err) {
      toast.error(getErrorMessage(err, t`Failed to import data`));
    } finally {
      setDataImporting(false);
    }
  }, [crmId, pendingDataImport, queryClient, t]);

  return (
    <div className="space-y-6">
      <Section
        title={t`Identity`}
        description={t`Core information about this CRM`}
      >
        <div className="divide-y-0">
          <EditableFieldRow
            label={t`Name`}
            value={crm.crm.name}
            canEdit={isOwner}
            onSave={(value) => onUpdate({ name: value })}
            validate={(value) => validateName(t, value)}
            emphasize
          />

          <EditableFieldRow
            label={t`Description`}
            value={crm.crm.description}
            canEdit={isOwner}
            onSave={(value) => onUpdate({ description: value })}
            multiline
          />

          <FieldRow label={t`Entity ID`}>
            <DataChip value={crm.crm.id} truncate='middle' />
          </FieldRow>

          {crm.crm.fingerprint && (
            <FieldRow label={t`Fingerprint`}>
              <DataChip
                value={crm.crm.fingerprint}
                truncate='middle'
              />
            </FieldRow>
          )}

          {crm.crm.server && (
            <FieldRow label={t`Server`}>
              <DataChip value={crm.crm.server} />
            </FieldRow>
          )}
        </div>
      </Section>

      {isOwner && (
        <Section
          title={t`Delete crm`}
          description={t`Permanently delete this CRM and all its content.`}
          action={
            <Button
              variant="outline"
              onClick={() => setShowDeleteDialog(true)}
              disabled={isDeleting}
              size="sm"
            >
              <Trash2 className="size-4 me-2" />
              <Trans>Delete</Trans>
            </Button>
          }
        />
      )}

      <Section
        title={t`Data management`}
        description={t`Export or import the raw data content in this CRM.`}
        action={
          <div className="flex gap-2">
            <Button variant="outline" onClick={handleDataExport}>
              <FileDown className="size-4 me-1.5" />
              <Trans>Export data</Trans>
            </Button>
            {canDesign(crm.crm.access) && (
              <Button variant="outline" onClick={() => setDataImportOpen(true)}>
                <FileUp className="size-4 me-1.5" />
                <Trans>Import data</Trans>
              </Button>
            )}
          </div>
        }
      />

      <ConfirmDialog
        open={showDeleteDialog}
        onOpenChange={setShowDeleteDialog}
        title={t`Delete CRM?`}
        desc={t`This will permanently delete "${crm.crm.name}" and all its objects, comments, and attachments. This action cannot be undone.`}
        confirmText={t`Delete CRM`}
        destructive
        handleConfirm={onDelete}
        isLoading={isDeleting}
      />

      {/* Data Import dialog */}
      <DataImportDialog
        open={dataImportOpen}
        onOpenChange={setDataImportOpen}
        onSelect={(data: Record<string, unknown>, label: string) => {
          setPendingDataImport({ data, label });
          setDataConfirmOpen(true);
        }}
      />

      {/* Confirm data import dialog */}
      <ConfirmDialog
        open={dataConfirmOpen}
        onOpenChange={setDataConfirmOpen}
        title={t`Import data?`}
        desc={
          <Trans>
            This will import the data from{" "}
            <strong>{pendingDataImport?.label}</strong>. Objects will be appended to the existing records. Ensure the current design matches the classes and fields referenced in the file.
          </Trans>
        }
        confirmText={
          dataImporting ? (
            <>
              <Loader2 className="size-4 me-1.5 animate-spin" />
              <Trans>Importing...</Trans>
            </>
          ) : (
            t`Import data`
          )
        }
        handleConfirm={handleConfirmDataImport}
        isLoading={dataImporting}
      >
        <Button variant="outline" className="w-full" onClick={handleDataExport} disabled={dataImporting}>
          <FileDown className="size-4 me-1.5" />
          <Trans>Download backup first</Trans>
        </Button>
      </ConfirmDialog>
    </div>
  );
}

// Data Import dialog: upload JSON file
function DataImportDialog({
  open,
  onOpenChange,
  onSelect,
}: {
  open: boolean;
  onOpenChange: (open: boolean) => void;
  onSelect: (
    data: Record<string, unknown>,
    label: string,
  ) => void;
}) {
  const { t } = useLingui()
  const fileInputRef = useRef<HTMLInputElement>(null);

  // Handle file upload
  const handleFileChange = (e: React.ChangeEvent<HTMLInputElement>) => {
    const file = e.target.files?.[0];
    if (!file) return;

    const reader = new FileReader();
    reader.onload = () => {
      try {
        const data = JSON.parse(reader.result as string);
        onSelect(data, file.name);
      } catch {
        toast.error(t`Invalid JSON file`);
      }
    };
    reader.onerror = () => {
      toast.error(t`Failed to read file`);
    };
    reader.readAsText(file);

    // Reset input so the same file can be selected again
    e.target.value = "";
  };

  return (
    <ResponsiveDialog open={open} onOpenChange={onOpenChange}>
      <ResponsiveDialogContent>
        <ResponsiveDialogHeader>
          <ResponsiveDialogTitle><Trans>Import data</Trans></ResponsiveDialogTitle>
          <ResponsiveDialogDescription className="sr-only"><Trans>Import a data configuration</Trans></ResponsiveDialogDescription>
        </ResponsiveDialogHeader>

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
              <Upload className="size-4 me-1.5" />
              <Trans>Upload .json file</Trans>
            </Button>
          </div>
        </div>

        <ResponsiveDialogFooter>
          <Button variant="outline" onClick={() => onOpenChange(false)}>
            <Trans>Cancel</Trans>
          </Button>
        </ResponsiveDialogFooter>
      </ResponsiveDialogContent>
    </ResponsiveDialog>
  );
}

type Translator = ReturnType<typeof useLingui>["t"];

function validateName(t: Translator, name: string): string | null {
  if (!name.trim()) return t`CRM name is required`;
  if (name.length > 1000) return t`Name must be 1000 characters or less`;
  if (DISALLOWED_NAME_CHARS.test(name))
    return t`Name cannot contain < or > characters`;
  return null;
}


interface AccessTabProps {
  crmId: string;
}

function AccessTab({ crmId }: AccessTabProps) {
  const { t } = useLingui()
  const CRM_ACCESS_LEVELS: AccessLevel[] = [
    { value: "design", label: t`Design, create, edit, comment, and view` },
    { value: "write", label: t`Create, edit, comment, and view` },
    { value: "comment", label: t`Comment and view` },
    { value: "view", label: t`View only` },
    { value: "none", label: t`No access` },
  ];
  const [dialogOpen, setDialogOpen] = useState(false);
  const [userSearchQuery, setUserSearchQuery] = useState("");

  const {
    data: rulesData,
    isLoading: isLoadingRules,
    error: rulesErrorRaw,
    refetch: refetchRules,
  } = useQuery({
    queryKey: ["crms", "access-rules", crmId],
    queryFn: () => crmsApi.getAccessRules(crmId),
    retry: false,
    refetchOnWindowFocus: false,
  });

  const {
    data: userSearchData,
    isLoading: userSearchLoading,
    error: userSearchErrorRaw,
    refetch: refetchUserSearch,
  } = useQuery({
    queryKey: ["users", "search", userSearchQuery],
    queryFn: () => crmsApi.searchUsers(userSearchQuery),
    enabled: userSearchQuery.length >= 1,
    retry: false,
  });

  const {
    data: groupsData,
    error: groupsErrorRaw,
    refetch: refetchGroups,
  } = useQuery({
    queryKey: ["groups", "list"],
    queryFn: () => crmsApi.listGroups(),
    retry: false,
    refetchOnWindowFocus: false,
  });

  const rules = useMemo<AccessRule[]>(
    () => rulesData?.data?.rules ?? [],
    [rulesData],
  );
  const rulesError = rulesErrorRaw ?? null;
  const userSearchError =
    userSearchQuery.length >= 1 && userSearchErrorRaw
      ? userSearchErrorRaw
      : null;
  const groupsError = groupsErrorRaw ?? null;
  const canManageRules = !rulesError && !isLoadingRules && !!rulesData;

  const handleAdd = async (
    subject: string,
    subjectName: string,
    level: string
  ) => {
    if (!canManageRules) return;
    await toastAction(crmsApi.setAccessLevel(crmId, subject, level), {
      loading: t`Setting access...`,
      success: t`Access set for ${subjectName}`,
      error: (e) => getErrorMessage(e, t`Failed to set access level`),
    });
    await refetchRules();
  };

  const handleRevoke = async (subject: string) => {
    if (!canManageRules) return;
    try {
      await toastAction(crmsApi.revokeAccess(crmId, subject), {
        loading: t`Removing access...`,
        success: t`Access removed`,
        error: (e) => getErrorMessage(e, t`Failed to remove access`),
      });
      await refetchRules();
    } catch {
      // toast already shown
    }
  };

  const handleLevelChange = async (subject: string, newLevel: string) => {
    if (!canManageRules) return;
    try {
      await toastAction(crmsApi.setAccessLevel(crmId, subject, newLevel), {
        loading: t`Updating access...`,
        success: t`Access level updated`,
        error: (e) => getErrorMessage(e, t`Failed to update access level`),
      });
      await refetchRules();
    } catch {
      // toast already shown
    }
  };

  return (
    <Section
      title={t`Access Management`}
      description={t`Control who can view and interact with this CRM`}
    >
      <div className="space-y-4">
        <div className="flex justify-end">
          <Button onClick={() => setDialogOpen(true)} size="sm" disabled={!canManageRules}>
            <Plus className="h-4 w-4 me-2" />
            <Trans>Add rule</Trans>
          </Button>
        </div>

        <AccessDialog
          open={dialogOpen}
          onOpenChange={setDialogOpen}
          onAdd={handleAdd}
          levels={CRM_ACCESS_LEVELS}
          defaultLevel="comment"
          userSearchResults={userSearchData?.data?.results ?? []}
          userSearchLoading={userSearchLoading}
          userSearchError={userSearchError}
          onRetryUserSearch={() => {
            void refetchUserSearch();
          }}
          onUserSearch={setUserSearchQuery}
          groups={groupsData?.data?.groups ?? []}
          groupsError={groupsError}
          onRetryGroups={() => {
            void refetchGroups();
          }}
        />

        {rulesError ? (
          <GeneralError
            error={rulesError}
            minimal
            mode="inline"
            reset={() => {
              void refetchRules();
            }}
          />
        ) : (
          <AccessList
            rules={rules}
            levels={CRM_ACCESS_LEVELS}
            onLevelChange={handleLevelChange}
            onRevoke={handleRevoke}
            isLoading={isLoadingRules}
            error={null}
          />
        )}
      </div>
    </Section>
  );
}
