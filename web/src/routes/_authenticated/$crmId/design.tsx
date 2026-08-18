// Mochi CRM: Design editor page
// Copyright © 2026 Mochisoft OÜ
// SPDX-License-Identifier: AGPL-3.0-only
// This file is part of Mochi, licensed under the GNU AGPL v3 with the
// Mochi Application Interface Exception - see license.txt and license-exception.md.

// The page body is EntityDesignPage in @mochi/web, shared with the projects
// app. What stays here is the route, the wording and this app's design editor.
// CRM offers no built-in templates, so the import dialog is the file half only.

import { createFileRoute, Navigate, useNavigate } from "@tanstack/react-router";
import { Trans, useLingui } from '@lingui/react/macro'
import { EntityDesignPage } from "@mochi/web";
import crmsApi from "@/api/crms";
import type { CrmDetails } from "@/types";
import { canDesign } from "@/lib/access";
import { DesignEditor } from "@/features/editor";

export const Route = createFileRoute("/_authenticated/$crmId/design")({
  component: DesignPage,
});

function DesignPage() {
  const { t } = useLingui()
  const { crmId } = Route.useParams();
  const navigate = useNavigate();

  return (
    <EntityDesignPage<CrmDetails["crm"], CrmDetails>
      containerId={crmId}
      selectContainer={(details) => details.crm}
      queryKey="crm"
      api={crmsApi}
      canDesign={(details) => canDesign(details.crm.access)}
      renderRedirect={() => <Navigate to="/$crmId" params={{ crmId }} />}
      onBack={() => void navigate({ to: "/$crmId", params: { crmId } })}
      renderEditor={(details) => <DesignEditor crmId={crmId} crm={details} />}
      labels={{
        design: t`Design`,
        // `String(name)` rather than the bare variable, so the extracted message
        // keeps the positional placeholder this app already ships.
        pageTitle: (name) => (name ? t`${String(name)} - Design` : t`Design`),
        back: t`Back to CRM`,
        loadFailed: t`Failed to load CRM design`,
        pageActions: t`Open design actions`,
        exportAction: t`Export design`,
        importAction: t`Import design`,
        downloaded: (filename) => t`Downloaded ${filename}`,
        exportFailed: t`Failed to export design`,
        imported: t`Design imported`,
        importFailed: t`Failed to import design`,
        importTitle: t`Import design`,
        importDescription: t`Import a design configuration`,
        uploadFile: t`Upload .json file`,
        invalidJson: t`Invalid JSON file`,
        readFailed: t`Failed to read file`,
        cancel: t`Cancel`,
        replaceTitle: t`Replace design?`,
        // `String(label)` rather than the bare variable, so the extracted
        // message keeps the positional placeholder this app already ships.
        replaceDescription: (label) => (
          <Trans>
            This will replace the current design with{" "}
            <strong>{String(label)}</strong>. All existing classes,
            fields, options, and views will be deleted. Existing objects will
            not be deleted but may no longer appear in views.
          </Trans>
        ),
        replaceConfirm: t`Replace design`,
        replacing: t`Replacing...`,
        downloadBackup: t`Download backup first`,
      }}
    />
  );
}
