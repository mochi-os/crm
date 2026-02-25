import { useEffect, useMemo, useState } from "react";
import { Link } from "@tanstack/react-router";
import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query";
import {
  Main,
  Card,
  CardContent,
  Button,
  usePageTitle,
  CardSkeleton,
  GeneralError,
  EntityOnboardingEmptyState,
  PageHeader,
  SubscribeDialog,
  ConfirmDialog,
  DropdownMenu,
  DropdownMenuContent,
  DropdownMenuItem,
  DropdownMenuTrigger,
  getAppPath,
  getErrorMessage,
  toast,
} from "@mochi/common";
import { MoreHorizontal, Plus, Users } from "lucide-react";
import { useCrmsStore } from "@/stores/crms-store";
import { useSidebarContext } from "@/context/sidebar-context";
import { InlineCrmSearch } from "../components/inline-crm-search";
import { RecommendedCrms } from "../components/recommended-crms";
import crmsApi from "@/api/crms";

export function CrmsListPage() {
  const crms = useCrmsStore((state) => state.crms);
  const isLoading = useCrmsStore((state) => state.isLoading);
  const error = useCrmsStore((state) => state.error);
  const refresh = useCrmsStore((state) => state.refresh);
  const { openCreateDialog } = useSidebarContext();
  const [subscribeOpen, setSubscribeOpen] = useState(false);
  const [unsubscribeId, setUnsubscribeId] = useState<string | null>(null);
  const queryClient = useQueryClient();

  const unsubscribeMutation = useMutation({
    mutationFn: (crmId: string) => crmsApi.unsubscribe(crmId),
    onSuccess: () => {
      void refresh();
      queryClient.invalidateQueries({ queryKey: ["crms"] });
      setUnsubscribeId(null);
    },
    onError: (error) => {
      toast.error(getErrorMessage(error, "Failed to unsubscribe"));
    },
  });

  usePageTitle("CRMs");

  // Notification subscription check
  const { data: subscriptionData, refetch: refetchSubscription } = useQuery({
    queryKey: ["subscription-check", "crms"],
    queryFn: () => crmsApi.checkSubscription(),
    staleTime: Infinity,
  });

  useEffect(() => {
    if (!isLoading && crms.length > 0 && subscriptionData?.data?.exists === false) {
      setSubscribeOpen(true);
    }
  }, [isLoading, crms.length, subscriptionData?.data?.exists]);

  useEffect(() => {
    void refresh();
  }, [refresh]);

  // Set of subscribed crm IDs for inline search
  const subscribedCrmIds = useMemo(
    () =>
      new Set(
        crms.flatMap((p) =>
          [p.id, p.fingerprint].filter((x): x is string => !!x),
        ),
      ),
    [crms],
  );

  return (
    <>
      <PageHeader
        title="CRMs"
        icon={<Users className="size-4 md:size-5" />}
      />
      <Main>
        {error && (
          <div className="mb-4">
            <GeneralError error={new Error(error)} minimal mode="inline" />
          </div>
        )}
        {isLoading ? (
          <CardSkeleton count={3} />
        ) : crms.length === 0 ? (
          <EntityOnboardingEmptyState
            icon={Users}
            title="CRMs"
            description="You have no CRMs yet."
            searchSlot={<InlineCrmSearch subscribedIds={subscribedCrmIds} />}
            primaryActionSlot={(
              <Button variant="outline" onClick={openCreateDialog}>
                <Plus className="mr-2 h-4 w-4" />
                Create a new CRM
              </Button>
            )}
            secondarySlot={(
              <RecommendedCrms
                subscribedIds={subscribedCrmIds}
                onSubscribe={() => void refresh()}
              />
            )}
          />
        ) : (
          <div className="grid gap-4 sm:grid-cols-2 lg:grid-cols-3">
            {crms.map((crm) => (
              <Link
                key={crm.id}
                to="/$crmId"
                params={{ crmId: crm.fingerprint }}
              >
                <Card className="hover:border-primary/50 h-full cursor-pointer transition-colors">
                  <CardContent className="p-4">
                    <div className="flex items-start justify-between gap-2">
                      <Users className="text-muted-foreground mt-0.5 size-5 shrink-0" />
                      <div className="min-w-0 flex-1">
                        <h3 className="truncate font-medium">{crm.name}</h3>
                        {crm.description && (
                          <p className="text-muted-foreground mt-1 line-clamp-2 text-sm">
                            {crm.description}
                          </p>
                        )}
                      </div>
                      {crm.owner !== 1 && (
                        <DropdownMenu>
                          <DropdownMenuTrigger asChild>
                            <button
                              className="hover:bg-muted shrink-0 rounded p-1 transition-colors"
                              onClick={(e) => e.preventDefault()}
                            >
                              <MoreHorizontal className="text-muted-foreground size-4" />
                            </button>
                          </DropdownMenuTrigger>
                          <DropdownMenuContent align="end">
                            <DropdownMenuItem
                              onClick={(e) => {
                                e.preventDefault();
                                setUnsubscribeId(crm.id);
                              }}
                            >
                              Unsubscribe
                            </DropdownMenuItem>
                          </DropdownMenuContent>
                        </DropdownMenu>
                      )}
                    </div>
                  </CardContent>
                </Card>
              </Link>
            ))}
          </div>
        )}
      </Main>

      <ConfirmDialog
        open={!!unsubscribeId}
        onOpenChange={(open) => { if (!open) setUnsubscribeId(null); }}
        title="Unsubscribe"
        desc="Are you sure you want to unsubscribe from this CRM?"
        confirmText="Unsubscribe"
        destructive
        isLoading={unsubscribeMutation.isPending}
        handleConfirm={() => {
          if (unsubscribeId) unsubscribeMutation.mutate(unsubscribeId);
        }}
      />

      <SubscribeDialog
        open={subscribeOpen}
        onOpenChange={setSubscribeOpen}
        app="crm"
        label="CRM updates"
        appBase={getAppPath()}
        subscriptions={[
          { label: "CRM updates", type: "update", defaultEnabled: true },
          { label: "Assignments", type: "assignment", defaultEnabled: true },
        ]}
        onResult={() => refetchSubscription()}
      />
    </>
  );
}
