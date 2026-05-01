// Mochi CRMs: Activity list component
// Copyright Alistair Cunningham 2026

import { useQuery } from "@tanstack/react-query";
import { Activity } from "lucide-react";
import { EmptyState, EntityAvatar, ListSkeleton, useFormat, getAppPath } from "@mochi/web";
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
    return <EmptyState icon={Activity} title={"No activity yet"} className="py-4" />;
  }

  return (
    <div className="space-y-3">
      {activities.map((activity) => (
        <div
          key={activity.id}
          className="text-sm border-l-2 border-muted pl-3 py-1"
        >
          <div className="font-medium">
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
          </div>
          <div className="flex items-center gap-2 text-xs text-muted-foreground">
            <EntityAvatar
              src={`${getAppPath()}/${crmId}/-/activity/${activity.id}/asset/avatar`}
              styleUrl={`${getAppPath()}/${crmId}/-/activity/${activity.id}/asset/style`}
              seed={activity.user}
              name={activity.name || activity.user}
              size={16}
            />
            <span>{activity.name || activity.user}</span>
            <span>·</span>
            <span>{formatTimestamp(activity.created)}</span>
          </div>
        </div>
      ))}
    </div>
  );
}
