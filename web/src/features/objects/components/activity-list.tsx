// Mochi CRMs: Activity list component
// Copyright Alistair Cunningham 2026

import { useQuery } from "@tanstack/react-query";
import { Activity } from "lucide-react";
import { EmptyState, ListSkeleton } from "@mochi/common";
import crmsApi from "@/api/crms";

interface ActivityListProps {
  crmId: string;
  objectId: string;
}

export function ActivityList({ crmId, objectId }: ActivityListProps) {
  const { data, isLoading } = useQuery({
    queryKey: ["activity", crmId, objectId],
    queryFn: async () => {
      const response = await crmsApi.listActivity(crmId, objectId);
      return response.data.activities;
    },
  });

  const formatDate = (timestamp: number) => {
    const d = new Date(timestamp * 1000);
    const year = d.getFullYear();
    const month = String(d.getMonth() + 1).padStart(2, "0");
    const day = String(d.getDate()).padStart(2, "0");
    const hours = String(d.getHours()).padStart(2, "0");
    const minutes = String(d.getMinutes()).padStart(2, "0");
    const seconds = String(d.getSeconds()).padStart(2, "0");
    return `${year}-${month}-${day} ${hours}:${minutes}:${seconds}`;
  };

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
    return <EmptyState icon={Activity} title="No activity yet" className="py-4" />;
  }

  return (
    <div className="space-y-3">
      {activities.map((activity) => (
        <div
          key={activity.id}
          className="text-sm border-l-2 border-muted pl-3 py-1"
        >
          <div className="flex items-center gap-2">
            <span className="text-xs text-muted-foreground">
              {formatDate(activity.created)}
            </span>
            <span className="font-medium">
              {activity.name || activity.user}
            </span>
          </div>
          <div className="text-muted-foreground">
            {formatAction(activity.action)}
            {activity.field && ` ${activity.field}`}
            {activity.oldvalue && activity.newvalue && (
              <>
                {": "}
                <span className="line-through">{activity.oldvalue}</span>
                {" → "}
                <span className="text-foreground">{activity.newvalue}</span>
              </>
            )}
          </div>
        </div>
      ))}
    </div>
  );
}
