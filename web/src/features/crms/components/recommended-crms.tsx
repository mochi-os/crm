import { useEffect, useState } from "react";
import { Button, Skeleton, toast, getErrorMessage } from "@mochi/common";
import { Users, Loader2 } from "lucide-react";
import crmsApi from "@/api/crms";

interface RecommendedCrmsProps {
  subscribedIds: Set<string>;
  onSubscribe: () => void;
}

interface RecommendedCrm {
  id: string;
  name: string;
  blurb: string;
  fingerprint: string;
}

export function RecommendedCrms({
  subscribedIds,
  onSubscribe,
}: RecommendedCrmsProps) {
  const [recommendations, setRecommendations] = useState<
    RecommendedCrm[]
  >([]);
  const [isLoading, setIsLoading] = useState(true);
  const [pendingId, setPendingId] = useState<string | null>(null);

  useEffect(() => {
    const fetchRecommendations = async () => {
      try {
        const response = await crmsApi.recommendations();
        setRecommendations(response.data?.crms ?? []);
      } catch {
        // Silently fail for recommendations
      } finally {
        setIsLoading(false);
      }
    };

    void fetchRecommendations();
  }, []);

  const handleSubscribe = async (crm: RecommendedCrm) => {
    setPendingId(crm.id);
    try {
      await crmsApi.subscribe(crm.id);
      onSubscribe();
      toast.success(`Subscribed to ${crm.name}`);
      setRecommendations((prev) => prev.filter((p) => p.id !== crm.id));
    } catch (error) {
      toast.error(getErrorMessage(error, "Failed to subscribe"));
    } finally {
      setPendingId(null);
    }
  };

  // Filter out already subscribed
  const filteredRecommendations = recommendations.filter(
    (rec) =>
      !subscribedIds.has(rec.id) && !subscribedIds.has(rec.fingerprint),
  );

  if (isLoading) {
    return (
      <>
        <hr className="my-6 w-full max-w-md border-t" />
        <div className="w-full max-w-md">
          <Skeleton className="mb-3 h-4 w-32" />
          <div className="divide-border divide-y rounded-lg border">
            {Array.from({ length: 3 }).map((_, i) => (
              <div key={i} className="flex items-center gap-3 px-4 py-3">
                <Skeleton className="h-8 w-8 rounded-md" />
                <div className="flex-1 space-y-1">
                  <Skeleton className="h-4 w-3/4" />
                  <Skeleton className="h-3 w-1/2" />
                </div>
                <Skeleton className="h-8 w-20" />
              </div>
            ))}
          </div>
        </div>
      </>
    );
  }

  if (filteredRecommendations.length === 0) {
    return null;
  }

  return (
    <>
      <hr className="my-6 w-full max-w-md border-t" />
      <div className="w-full max-w-md">
        <p className="text-muted-foreground mb-3 text-xs font-medium uppercase tracking-wide">
          Recommended CRMs
        </p>
        <div className="divide-border divide-y rounded-lg border text-left">
          {filteredRecommendations.map((crm) => {
            const isPending = pendingId === crm.id;

            return (
              <div
                key={crm.id}
                className="flex items-center justify-between gap-3 px-4 py-3 transition-colors hover:bg-muted/50"
              >
                <div className="flex min-w-0 flex-1 items-center gap-3">
                  <div className="flex h-8 w-8 shrink-0 items-center justify-center rounded-md bg-purple-500/10">
                    <Users className="h-4 w-4 text-purple-600" />
                  </div>
                  <div className="flex min-w-0 flex-1 flex-col">
                    <span className="truncate text-sm font-medium">
                      {crm.name}
                    </span>
                    {crm.blurb && (
                      <span className="text-muted-foreground truncate text-xs">
                        {crm.blurb}
                      </span>
                    )}
                  </div>
                </div>
                <Button
                  size="sm"
                  onClick={() => handleSubscribe(crm)}
                  disabled={isPending}
                >
                  {isPending ? (
                    <Loader2 className="h-4 w-4 animate-spin" />
                  ) : (
                    "Subscribe"
                  )}
                </Button>
              </div>
            );
          })}
        </div>
      </div>
    </>
  );
}
