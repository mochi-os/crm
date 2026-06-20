// Mochi CRMs: Activity list component
// Copyright © 2026 Mochi OÜ
// SPDX-License-Identifier: AGPL-3.0-only
// This file is part of Mochi, licensed under the GNU AGPL v3 with the
// Mochi Application Interface Exception - see license.txt and license-exception.md.

import { useQuery } from "@tanstack/react-query";
import { t } from '@lingui/core/macro'
import { Activity } from "lucide-react";
import { ActivityTimeline, EmptyState, EntityAvatar, ListSkeleton, useFormat, getAppPath } from "@mochi/web";
import crmsApi from "@/api/crms";

interface ActivityListProps {
  crmId: string;
  objectId: string;
}

export function ActivityList({ crmId, objectId }: ActivityListProps) {
  const { formatTimestamp } = useFormat()
  const { data, isLoading } = useQuery({
    queryKey: ["activity", crmId, objectId],
    queryFn: async () => {
      const response = await crmsApi.listActivity(crmId, objectId);
      return response.data.activities;
    },
  });

  const formatAction = (action: string) => {
    switch (action) {
      case "create":
        return "created";
      case "update":
        return "updated";
      case "delete":
        return "deleted";
      case "move":
        return "moved";
      default:
        return action;
    }
  };

  if (isLoading) {
    return <ListSkeleton count={3} variant="simple" height="h-10" />;
  }

  const activities = data || [];

  if (activities.length === 0) {
    return <EmptyState icon={Activity} title={t`No activity yet`} className="py-4" />;
  }

  return (
    <ActivityTimeline
      items={activities.map((activity) => ({
        id: activity.id,
        primary: (
          <p className="text-sm font-medium">
            {formatAction(activity.action)}
            {activity.field && ` ${activity.field}`}
            {activity.oldvalue && activity.newvalue && (
              <>
                {": "}
                <span className="line-through font-normal text-muted-foreground">{activity.oldvalue}</span>
                {" → "}
                <span>{activity.newvalue}</span>
              </>
            )}
          </p>
        ),
        secondary: (
          <div className="flex items-center gap-2 text-xs text-muted-foreground">
            <EntityAvatar
              src={`${getAppPath()}/${crmId}/-/activity/${activity.id}/asset/avatar`}
              styleUrl={`${getAppPath()}/${crmId}/-/activity/${activity.id}/asset/style`}
              seed={activity.user}
              name={activity.name || activity.user}
              size="xs"
            />
            <span>{activity.name || activity.user}</span>
            <span>·</span>
            <span>{formatTimestamp(activity.created)}</span>
          </div>
        ),
      }))}
    />
  );
}
