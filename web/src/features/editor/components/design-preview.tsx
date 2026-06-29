// Mochi CRMs: Design preview component
// Copyright © 2026 Mochi OÜ
// SPDX-License-Identifier: AGPL-3.0-only
// This file is part of Mochi, licensed under the GNU AGPL v3 with the
// Mochi Application Interface Exception - see license.txt and license-exception.md.

import { useMemo, useState, useEffect } from "react";
import { Trans } from '@lingui/react/macro'
import { ViewTabs } from "@mochi/web";
import type { CrmDetails, CrmObject } from "@/types";
import { BoardContainer } from "@/features/board/components/board-container";
import { TreeView } from "@/features/tree/components/tree-view";

interface DesignPreviewProps {
  crm: CrmDetails;
  crmId: string;
  objects: CrmObject[];
  selectedClassId: string | null;
}

export function DesignPreview({
  crm,
  crmId,
  objects,
  selectedClassId: _selectedClassId,
}: DesignPreviewProps) {
  const [selectedViewId, setSelectedViewId] = useState<string | null>(
    crm.views[0]?.id || null,
  );

  // Sync to editor's class selection: pick the first view for that class
  useEffect(() => {
    if (!_selectedClassId) return;
    const match = crm.views.find(
      (v) => v.classes.length === 0 || v.classes.includes(_selectedClassId),
    );
    if (match) setSelectedViewId(match.id);
  }, [_selectedClassId, crm.views]);

  const selectedView = crm.views.find((v) => v.id === selectedViewId);

  // Filter objects to the view's classes (or show all if view has no class filter)
  const viewClasses = useMemo(() => selectedView?.classes || [], [selectedView]);
  const classObjects = useMemo(
    () => viewClasses.length > 0
      ? objects.filter((obj) => viewClasses.includes(obj.class))
      : objects,
    [objects, viewClasses],
  );

  const noop = () => {};

  return (
    <div className="h-full flex flex-col">
      <div className="overflow-x-auto no-scrollbar border-b">
        <div className="flex items-center px-4 py-2 min-w-max">
          <ViewTabs
            variant="pill"
            views={crm.views}
            activeViewId={selectedViewId || ""}
            onViewChange={setSelectedViewId}
          />
        </div>
      </div>
      <div className="flex-1 p-4 overflow-auto">
        {selectedView ? (
          selectedView.viewtype === "board"
            ? <BoardContainer
                crm={crm}
                objects={classObjects}
                statusField={selectedView.columns || ""}
                rowField={selectedView.rows || undefined}
                borderField={selectedView.border || undefined}
                viewFields={selectedView.fields}
                viewClasses={selectedView.classes}
                preview
              />
            : <TreeView
                crm={crm}
                crmId={crmId}
                objects={classObjects}
                peopleMap={{}}
                viewFields={selectedView.fields}
                viewClasses={selectedView.classes}
                statusField={selectedView.columns}
                borderField={selectedView.border || undefined}
                onCardClick={noop}
                preview
              />
        ) : (
          <div className="text-sm text-muted-foreground text-center py-8">
            <Trans>No views</Trans>
          </div>
        )}
      </div>
    </div>
  );
}
