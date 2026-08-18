// Mochi CRM: CRM settings page
// Copyright © 2026 Mochisoft OÜ
// SPDX-License-Identifier: AGPL-3.0-only
// This file is part of Mochi, licensed under the GNU AGPL v3 with the
// Mochi Application Interface Exception - see license.txt and license-exception.md.

// The page body is EntitySettingsPage in @mochi/web, shared with the projects
// app. What stays here is the route and its tab param, the wording, the name
// rules and the access ladder.

import { createFileRoute, useNavigate } from "@tanstack/react-router";
import { useLingui } from '@lingui/react/macro'
import {
  EntitySettingsPage,
  type AccessLevel,
  type EntitySettingsTab,
} from "@mochi/web";
import { Users } from "lucide-react";
import crmsApi from "@/api/crms";
import type { CrmDetails } from "@/types";
import { useCrmsStore } from "@/stores/crms-store";

// Characters disallowed in CRM names (matches backend validation)
const DISALLOWED_NAME_CHARS = /[<>\r\n]/;

type SettingsSearch = {
  tab?: EntitySettingsTab;
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

function CrmSettingsPage() {
  const { t } = useLingui()
  const { crmId } = Route.useParams();
  const navigate = useNavigate();
  const navigateSettings = Route.useNavigate();
  const { tab } = Route.useSearch();
  const refreshSidebar = useCrmsStore((state) => state.refresh);

  const accessLevels: AccessLevel[] = [
    { value: "design", label: t`Design, create, edit, comment, and view` },
    { value: "write", label: t`Create, edit, comment, and view` },
    { value: "comment", label: t`Comment and view` },
    { value: "view", label: t`View only` },
    { value: "none", label: t`No access` },
  ];

  return (
    <EntitySettingsPage<CrmDetails["crm"], CrmDetails>
      containerId={crmId}
      selectContainer={(details) => details.crm}
      queryKey="crm"
      accessRulesKey="crms"
      api={crmsApi}
      icon={Users}
      accessLevels={accessLevels}
      activeTab={tab ?? "general"}
      onTabChange={(newTab) =>
        void navigateSettings({ search: { tab: newTab }, replace: true })
      }
      onBack={() => void navigate({ to: "/$crmId", params: { crmId } })}
      onDeleted={() => void navigate({ to: "/" })}
      refreshSidebar={refreshSidebar}
      validateName={(name) => {
        if (!name.trim()) return t`CRM name is required`;
        if (name.length > 1000) return t`Name must be 1000 characters or less`;
        if (DISALLOWED_NAME_CHARS.test(name))
          return t`Name cannot contain < or > characters`;
        return null;
      }}
      labels={{
        settings: t`Settings`,
        access: t`Access`,
        back: t`Back to CRM`,
        // `String(name)` rather than the bare variable, so the extracted message
        // keeps the positional placeholder this app already ships.
        pageTitle: (name) => (name ? t`${String(name)} settings` : t`CRM settings`),
        notFound: t`CRM not found`,
        notFoundDescription: t`This CRM may have been deleted or you don't have access to it.`,
        unavailable: t`CRM unavailable`,
        unavailableDescription: t`This CRM could not be loaded right now.`,
        identity: t`Identity`,
        name: t`Name`,
        description: t`Description`,
        entityId: t`Entity ID`,
        fingerprint: t`Fingerprint`,
        server: t`Server`,
        saving: t`Saving...`,
        updated: t`CRM updated`,
        updateFailed: t`Failed to update CRM`,
        deleteSection: t`Delete CRM`,
        delete: t`Delete`,
        deleteTitle: t`Delete CRM?`,
        deleteConfirm: t`Delete CRM`,
        deleteDescription: (name) =>
          t`This will permanently delete "${String(name)}" and all its objects, comments, and attachments. This action cannot be undone.`,
        deleting: t`Deleting CRM...`,
        deleted: t`CRM deleted`,
        deleteFailed: t`Failed to delete CRM`,
        accessManagement: t`Access management`,
        addRule: t`Add rule`,
        settingAccess: t`Setting access...`,
        accessSet: (subjectName) => t`Access set for ${subjectName}`,
        setAccessFailed: t`Failed to set access level`,
        removingAccess: t`Removing access...`,
        accessRemoved: t`Access removed`,
        removeAccessFailed: t`Failed to remove access`,
        updatingAccess: t`Updating access...`,
        accessUpdated: t`Access level updated`,
        updateAccessFailed: t`Failed to update access level`,
      }}
    />
  );
}
