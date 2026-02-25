// Mochi CRM: CRM settings page
// Copyright Alistair Cunningham 2026

import { createFileRoute, useNavigate } from "@tanstack/react-router";
import { useCallback, useEffect, useState } from "react";
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
  PageHeader,
  Main,
  cn,
  usePageTitle,
  Input,
  Textarea,
  EmptyState,
  Skeleton,
  Section,
  FieldRow,
  DataChip,
  toast,
  getErrorMessage,
  AccessDialog,
  AccessList,
  type AccessLevel,
} from "@mochi/common";
import {
  Loader2,
  Users,
  Settings,
  Shield,
  Trash2,
  Pencil,
  Check,
  X,
  Plus,
} from "lucide-react";
import crmsApi from "@/api/crms";
import type { AccessRule } from "@mochi/common";
import type { CrmDetails } from "@/types";
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

const tabs: Tab[] = [
  { id: "general", label: "Settings", icon: <Settings className="h-4 w-4" /> },
  { id: "access", label: "Access", icon: <Shield className="h-4 w-4" /> },
];

function CrmSettingsPage() {
  const { crmId } = Route.useParams();
  const navigate = useNavigate();
  const navigateSettings = Route.useNavigate();
  const { tab } = Route.useSearch();
  const activeTab = tab ?? "general";
  const queryClient = useQueryClient();
  const refreshSidebar = useCrmsStore((state) => state.refresh);

  const setActiveTab = (newTab: TabId) => {
    void navigateSettings({ search: { tab: newTab }, replace: true });
  };

  const [isDeleting, setIsDeleting] = useState(false);
  const [isUnsubscribing, setIsUnsubscribing] = useState(false);
  const [showDeleteDialog, setShowDeleteDialog] = useState(false);

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
  const isOwner = crm?.crm.owner === 1;

  usePageTitle(
    crm ? `${crm.crm.name} settings` : "Crm settings"
  );

  const handleDelete = useCallback(async () => {
    if (!crm || !isOwner || isDeleting) return;

    setIsDeleting(true);
    try {
      await crmsApi.delete(crm.crm.id);
      void refreshSidebar();
      toast.success("Crm deleted");
      void navigate({ to: "/" });
    } catch (err) {
      toast.error(getErrorMessage(err, "Failed to delete crm"));
    } finally {
      setIsDeleting(false);
    }
  }, [crm, isOwner, isDeleting, refreshSidebar, navigate]);

  const handleUnsubscribe = useCallback(async () => {
    if (!crm || isUnsubscribing) return;

    setIsUnsubscribing(true);
    try {
      await crmsApi.unsubscribe(crm.crm.id);
      void refreshSidebar();
      toast.success("Unsubscribed");
      void navigate({ to: "/" });
    } catch (err) {
      toast.error(getErrorMessage(err, "Failed to unsubscribe"));
    } finally {
      setIsUnsubscribing(false);
    }
  }, [crm, isUnsubscribing, refreshSidebar, navigate]);

  const handleUpdate = useCallback(
    async (updates: {
      name?: string;
      description?: string;
    }) => {
      if (!crm || !isOwner) return;

      try {
        await crmsApi.update(crm.crm.id, updates);
        void refreshSidebar();
        queryClient.invalidateQueries({ queryKey: ["crm", crmId] });
        toast.success("Crm updated");
      } catch (err) {
        toast.error(getErrorMessage(err, "Failed to update crm"));
        throw err;
      }
    },
    [crm, isOwner, refreshSidebar, queryClient, crmId]
  );

  if (isLoading) {
    return (
      <>
        <PageHeader
          title="Settings"
          icon={<Settings className="size-4 md:size-5" />}
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

  if (error || !crm) {
    return (
      <>
        <PageHeader
          title="Settings"
          icon={<Settings className="size-4 md:size-5" />}
        />
        <Main>
          <EmptyState
            icon={Users}
            title="Crm not found"
            description="This crm may have been deleted or you don't have access to it."
          />
        </Main>
      </>
    );
  }

  return (
    <>
      <PageHeader
        title={`${crm.crm.name} settings`}
        icon={<Settings className="size-4 md:size-5" />}
      />
      <Main className="space-y-6">
        {/* Tabs - only show for owners */}
        {isOwner && (
          <div className="flex gap-1 border-b">
            {tabs.map((t) => (
              <button
                key={t.id}
                onClick={() => setActiveTab(t.id)}
                className={cn(
                  "flex items-center gap-2 px-4 py-2 text-sm font-medium transition-colors",
                  "border-b-2 -mb-px",
                  activeTab === t.id
                    ? "border-primary text-foreground"
                    : "border-transparent text-muted-foreground hover:text-foreground"
                )}
              >
                {t.icon}
                {t.label}
              </button>
            ))}
          </div>
        )}

        {/* Tab content */}
        <div className="pt-2">
          {activeTab === "general" && (
            <GeneralTab
              crm={crm}
              isOwner={isOwner}
              isDeleting={isDeleting}
              isUnsubscribing={isUnsubscribing}
              showDeleteDialog={showDeleteDialog}
              setShowDeleteDialog={setShowDeleteDialog}
              onDelete={handleDelete}
              onUnsubscribe={handleUnsubscribe}
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
  isUnsubscribing: boolean;
  showDeleteDialog: boolean;
  setShowDeleteDialog: (show: boolean) => void;
  onDelete: () => void;
  onUnsubscribe: () => void;
  onUpdate: (updates: {
    name?: string;
    description?: string;
  }) => Promise<void>;
}

function GeneralTab({
  crm,
  isOwner,
  isDeleting,
  isUnsubscribing,
  showDeleteDialog,
  setShowDeleteDialog,
  onDelete,
  onUnsubscribe,
  onUpdate,
}: GeneralTabProps) {
  return (
    <div className="space-y-6">
      <Section
        title="Identity"
        description="Core information about this crm"
      >
        <div className="divide-y-0">
          <EditableFieldRow
            label="Name"
            value={crm.crm.name}
            isOwner={isOwner}
            onSave={(value) => onUpdate({ name: value })}
            validate={validateName}
          />

          <EditableFieldRow
            label="Description"
            value={crm.crm.description}
            isOwner={isOwner}
            onSave={(value) => onUpdate({ description: value })}
            multiline
          />

          <FieldRow label="Entity ID">
            <DataChip value={crm.crm.id} truncate='middle' />
          </FieldRow>

          {crm.crm.fingerprint && (
            <FieldRow label="Fingerprint">
              <DataChip
                value={crm.crm.fingerprint}
                truncate='middle'
              />
            </FieldRow>
          )}

          {crm.crm.server && (
            <FieldRow label="Server">
              <DataChip value={crm.crm.server} />
            </FieldRow>
          )}
        </div>
      </Section>

      {!isOwner && (
        <Section
          title="Unsubscribe from crm"
          action={
            <Button
              variant="outline"
              onClick={onUnsubscribe}
              disabled={isUnsubscribing}
              size="sm"
            >
              {isUnsubscribing ? (
                <Loader2 className="mr-2 size-4 animate-spin" />
              ) : (
                "Unsubscribe"
              )}
            </Button>
          }
        />
      )}

      {isOwner && (
        <Section
          title="Delete crm"
          description="Permanently delete this crm and all its content."
          action={
            <Button
              variant="outline"
              onClick={() => setShowDeleteDialog(true)}
              disabled={isDeleting}
              size="sm"
            >
              <Trash2 className="size-4 mr-2" />
              Delete
            </Button>
          }
        />
      )}

      <AlertDialog open={showDeleteDialog} onOpenChange={setShowDeleteDialog}>
        <AlertDialogContent>
          <AlertDialogHeader>
            <AlertDialogTitle>Delete crm?</AlertDialogTitle>
            <AlertDialogDescription>
              This will permanently delete "{crm.crm.name}" and all its
              objects, comments, and attachments. This action cannot be undone.
            </AlertDialogDescription>
          </AlertDialogHeader>
          <AlertDialogFooter>
            <AlertDialogCancel>Cancel</AlertDialogCancel>
            <AlertDialogAction variant="destructive" onClick={onDelete}>
              Delete crm
            </AlertDialogAction>
          </AlertDialogFooter>
        </AlertDialogContent>
      </AlertDialog>
    </div>
  );
}

function validateName(name: string): string | null {
  if (!name.trim()) return "Crm name is required";
  if (name.length > 1000) return "Name must be 1000 characters or less";
  if (DISALLOWED_NAME_CHARS.test(name))
    return "Name cannot contain < or > characters";
  return null;
}

interface EditableFieldRowProps {
  label: string;
  value: string;
  isOwner: boolean;
  onSave: (value: string) => Promise<void>;
  validate?: (value: string) => string | null;
  multiline?: boolean;
}

function EditableFieldRow({
  label,
  value,
  isOwner,
  onSave,
  validate,
  multiline,
}: EditableFieldRowProps) {
  const [isEditing, setIsEditing] = useState(false);
  const [editValue, setEditValue] = useState(value);
  const [isSaving, setIsSaving] = useState(false);
  const [error, setError] = useState<string | null>(null);

  const handleStartEdit = () => {
    setEditValue(value);
    setError(null);
    setIsEditing(true);
  };

  const handleCancelEdit = () => {
    setIsEditing(false);
    setEditValue(value);
    setError(null);
  };

  const handleSaveEdit = async () => {
    const trimmedValue = editValue.trim();
    if (validate) {
      const validationError = validate(trimmedValue);
      if (validationError) {
        setError(validationError);
        return;
      }
    }
    if (trimmedValue === value) {
      setIsEditing(false);
      return;
    }
    setIsSaving(true);
    try {
      await onSave(trimmedValue);
      setIsEditing(false);
    } finally {
      setIsSaving(false);
    }
  };

  return (
    <FieldRow label={label}>
      {isOwner && isEditing ? (
        <div className="flex flex-col gap-1 w-full max-w-md">
          <div className="flex items-start gap-2">
            {multiline ? (
              <Textarea
                value={editValue}
                onChange={(e) => {
                  setEditValue(e.target.value);
                  setError(null);
                }}
                onKeyDown={(e) => {
                  if (e.key === "Escape") handleCancelEdit();
                }}
                className="min-h-[80px]"
                disabled={isSaving}
                autoFocus
              />
            ) : (
              <Input
                value={editValue}
                onChange={(e) => {
                  setEditValue(e.target.value);
                  setError(null);
                }}
                onKeyDown={(e) => {
                  if (e.key === "Enter") void handleSaveEdit();
                  if (e.key === "Escape") handleCancelEdit();
                }}
                className="h-9"
                disabled={isSaving}
                autoFocus
              />
            )}
            <Button
              size="sm"
              variant="ghost"
              onClick={() => void handleSaveEdit()}
              disabled={isSaving}
              className="h-9 w-9 p-0 shrink-0"
            >
              {isSaving ? (
                <Loader2 className="size-4 animate-spin" />
              ) : (
                <Check className="size-4 text-green-600" />
              )}
            </Button>
            <Button
              size="sm"
              variant="ghost"
              onClick={handleCancelEdit}
              disabled={isSaving}
              className="h-9 w-9 p-0 shrink-0"
            >
              <X className="size-4 text-destructive" />
            </Button>
          </div>
          {error && <span className="text-sm text-destructive">{error}</span>}
        </div>
      ) : (
        <div className="flex items-center gap-2">
          {value ? (
            <span className={label === "Name" ? "text-base font-semibold" : ""}>
              {value}
            </span>
          ) : (
            <span className="text-muted-foreground italic">Not set</span>
          )}
          {isOwner && (
            <Button
              size="sm"
              variant="ghost"
              onClick={handleStartEdit}
              className="h-6 w-6 p-0 hover:bg-muted"
            >
              <Pencil className="size-3.5 text-muted-foreground" />
            </Button>
          )}
        </div>
      )}
    </FieldRow>
  );
}

// Access levels for crms
const CRM_ACCESS_LEVELS: AccessLevel[] = [
  { value: "design", label: "Design, write, comment, and view" },
  { value: "write", label: "Write, comment, and view" },
  { value: "comment", label: "Comment and view" },
  { value: "view", label: "View only" },
  { value: "none", label: "No access" },
];

interface AccessTabProps {
  crmId: string;
}

function AccessTab({ crmId }: AccessTabProps) {
  const [rules, setRules] = useState<AccessRule[]>([]);
  const [isLoading, setIsLoading] = useState(true);
  const [error, setError] = useState<Error | null>(null);

  const [dialogOpen, setDialogOpen] = useState(false);
  const [userSearchQuery, setUserSearchQuery] = useState("");

  const { data: userSearchData, isLoading: userSearchLoading } = useQuery({
    queryKey: ["users", "search", userSearchQuery],
    queryFn: () => crmsApi.searchUsers(userSearchQuery),
    enabled: userSearchQuery.length >= 1,
  });

  const { data: groupsData } = useQuery({
    queryKey: ["groups", "list"],
    queryFn: () => crmsApi.listGroups(),
  });

  const loadRules = useCallback(async () => {
    setIsLoading(true);
    setError(null);
    try {
      const response = await crmsApi.getAccessRules(crmId);
      setRules(response.data?.rules ?? []);
    } catch (err) {
      setError(
        err instanceof Error ? err : new Error("Failed to load access rules")
      );
    } finally {
      setIsLoading(false);
    }
  }, [crmId]);

  useEffect(() => {
    void loadRules();
  }, [loadRules]);

  const handleAdd = async (
    subject: string,
    subjectName: string,
    level: string
  ) => {
    try {
      await crmsApi.setAccessLevel(crmId, subject, level);
      toast.success(`Access set for ${subjectName}`);
      void loadRules();
    } catch (err) {
      toast.error(getErrorMessage(err, "Failed to set access level"));
      throw err;
    }
  };

  const handleRevoke = async (subject: string) => {
    try {
      await crmsApi.revokeAccess(crmId, subject);
      toast.success("Access removed");
      void loadRules();
    } catch (err) {
      toast.error(getErrorMessage(err, "Failed to remove access"));
    }
  };

  const handleLevelChange = async (subject: string, newLevel: string) => {
    try {
      await crmsApi.setAccessLevel(crmId, subject, newLevel);
      toast.success("Access level updated");
      void loadRules();
    } catch (err) {
      toast.error(getErrorMessage(err, "Failed to update access level"));
    }
  };

  return (
    <Section
      title="Access Management"
      description="Control who can view and interact with this crm"
    >
      <div className="space-y-4">
        <div className="flex justify-end">
          <Button onClick={() => setDialogOpen(true)} size="sm">
            <Plus className="h-4 w-4 mr-2" />
            Add Rule
          </Button>
        </div>

        <AccessDialog
          open={dialogOpen}
          onOpenChange={setDialogOpen}
          onAdd={handleAdd}
          levels={CRM_ACCESS_LEVELS}
          defaultLevel="comment"
          userSearchResults={userSearchData?.results ?? []}
          userSearchLoading={userSearchLoading}
          onUserSearch={setUserSearchQuery}
          groups={groupsData?.groups ?? []}
        />

        <AccessList
          rules={rules}
          levels={CRM_ACCESS_LEVELS}
          onLevelChange={handleLevelChange}
          onRevoke={handleRevoke}
          isLoading={isLoading}
          error={error}
        />
      </div>
    </Section>
  );
}
