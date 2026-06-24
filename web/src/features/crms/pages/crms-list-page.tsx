// Copyright © 2026 Mochi OÜ
// SPDX-License-Identifier: AGPL-3.0-only
// This file is part of Mochi, licensed under the GNU AGPL v3 with the
// Mochi Application Interface Exception - see license.txt and license-exception.md.

import { useEffect, useMemo, useState } from "react";
import { Trans, useLingui } from '@lingui/react/macro'
import { Link } from "@tanstack/react-router";
import { useMutation, useQueryClient } from "@tanstack/react-query";
import {
  Main,
  Button,
  usePageTitle,
  CardSkeleton,
  GeneralError,
  EntityOnboardingEmptyState,
  PageHeader,
  ConfirmDialog,
  DropdownMenu,
  DropdownMenuContent,
  DropdownMenuItem,
  DropdownMenuTrigger,
  ListCard,
  getErrorMessage,
  toastAction,
  Tooltip,
  TooltipContent,
  TooltipTrigger,
} from "@mochi/web";
import { Ellipsis, Plus, Users } from "lucide-react";
import { useCrmsStore } from "@/stores/crms-store";
import { useSidebarContext } from "@/context/sidebar-context";
import { InlineCrmSearch } from "../components/inline-crm-search";
import { RecommendedCrms } from "../components/recommended-crms";
import crmsApi from "@/api/crms";

export function CrmsListPage() {
  const { t } = useLingui()
  const crms = useCrmsStore((state) => state.crms);
  const isLoading = useCrmsStore((state) => state.isLoading);
  const error = useCrmsStore((state) => state.error);
  const refresh = useCrmsStore((state) => state.refresh);
  const { openCreateDialog } = useSidebarContext();
  const [unsubscribeId, setUnsubscribeId] = useState<string | null>(null);
  const queryClient = useQueryClient();

  const unsubscribeMutation = useMutation({
    mutationFn: (crmId: string) => crmsApi.unsubscribe(crmId),
    onSuccess: () => {
      void refresh();
      queryClient.invalidateQueries({ queryKey: ["crms"] });
      setUnsubscribeId(null);
    },
  });

  usePageTitle(t`CRMs`);

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
        title={t`CRMs`}
        icon={<Users className="size-4 md:size-5" />}
      />
      <Main>
        {error && (
          <div className="mb-4">
            <GeneralError
              error={new Error(error)}
              minimal
              mode="inline"
              reset={() => {
                void refresh();
              }}
            />
          </div>
        )}
        {isLoading ? (
          <CardSkeleton count={3} />
        ) : crms.length === 0 ? (
          <EntityOnboardingEmptyState
            icon={Users}
            title={t`CRMs`}
            description={t`You have no CRMs yet.`}
            searchSlot={<InlineCrmSearch subscribedIds={subscribedCrmIds} />}
            primaryActionSlot={(
              <Button variant="outline" onClick={openCreateDialog}>
                <Plus className="me-2 h-4 w-4" />
                <Trans>Create a new CRM</Trans>
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
          <div className="grid gap-3 sm:grid-cols-2 xl:grid-cols-3">
            {crms.map((crm) => {
              const isSubscribed = crm.owner !== 1
              return (
                <ListCard
                  key={crm.id}
                  icon={<Users className="size-5" />}
                  title={crm.name}
                  highlighted={isSubscribed}
                  renderLink={(className) => (
                    <Link to="/$crmId" params={{ crmId: crm.fingerprint }} className={className}>
                      <span className="sr-only"><Trans>Open {crm.name}</Trans></span>
                    </Link>
                  )}
                  menu={isSubscribed && (
                    <DropdownMenu>
                      <Tooltip>
                        <TooltipTrigger asChild>
                          <DropdownMenuTrigger asChild>
                            <Button
                              variant="ghost"
                              size="icon"
                              aria-label={t`CRM actions`}
                              className="size-8 opacity-0 transition-opacity group-hover:opacity-100 data-[state=open]:opacity-100"
                            >
                              <Ellipsis className="size-4" />
                            </Button>
                          </DropdownMenuTrigger>
                        </TooltipTrigger>
                        <TooltipContent>{t`CRM actions`}</TooltipContent>
                      </Tooltip>
                      <DropdownMenuContent align="end">
                        <DropdownMenuItem onSelect={() => setUnsubscribeId(crm.id)}>
                          <Trans>Unsubscribe</Trans>
                        </DropdownMenuItem>
                      </DropdownMenuContent>
                    </DropdownMenu>
                  )}
                >
                  {crm.description && (
                    <p className="text-muted-foreground mt-1 line-clamp-2 text-sm">{crm.description}</p>
                  )}
                </ListCard>
              )
            })}
          </div>
        )}
      </Main>

      <ConfirmDialog
        open={!!unsubscribeId}
        onOpenChange={(open) => { if (!open) setUnsubscribeId(null); }}
        title={t`Unsubscribe`}
        desc={t`Are you sure you want to unsubscribe from this CRM?`}
        confirmText={t`Unsubscribe`}
        destructive
        isLoading={unsubscribeMutation.isPending}
        handleConfirm={async () => {
          if (!unsubscribeId) return;
          try {
            await toastAction(unsubscribeMutation.mutateAsync(unsubscribeId), {
              loading: t`Unsubscribing...`,
              success: t`Unsubscribed`,
              error: (e) => getErrorMessage(e, t`Failed to unsubscribe`),
            });
          } catch {
            // toast already shown
          }
        }}
      />

    </>
  );
}
