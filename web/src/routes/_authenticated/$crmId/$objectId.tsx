// Mochi CRM: Object deep-link route
// Copyright Alistair Cunningham 2026

import { createFileRoute, redirect, useNavigate, useRouter } from "@tanstack/react-router";
import {
  GeneralError,
  extractStatus,
  getErrorMessage,
  Main,
  PageHeader,
} from "@mochi/web";
import { Users } from "lucide-react";
import crmsApi from "@/api/crms";
import type { CrmDetails } from "@/types";
import { CrmPageContent } from "./index";

interface SearchParams {
  view?: string;
}

export const Route = createFileRoute("/_authenticated/$crmId/$objectId")({
  validateSearch: (search: Record<string, unknown>): SearchParams => ({
    view: typeof search.view === "string" ? search.view : undefined,
  }),
  loader: async ({ params }) => {
    try {
      const crmResponse = await crmsApi.get(params.crmId);
      return { crm: crmResponse.data, loaderError: null };
    } catch (error) {
      const status = extractStatus(error);
      if (status === 403 || status === 404) {
        throw redirect({ to: "/" });
      }

      return {
        crm: null as CrmDetails | null,
        loaderError:
          getErrorMessage(error, "Failed to load CRM"),
      };
    }
  },
  component: ObjectPage,
});

function ObjectPage() {
  const { crm, loaderError } = Route.useLoaderData() as {
    crm: CrmDetails | null;
    loaderError: string | null;
  };
  const params = Route.useParams();
  const search = Route.useSearch();
  const navigate = useNavigate();
  const router = useRouter();

  if (!crm) {
    return (
      <>
        <PageHeader
          title="CRM"
          icon={<Users className="size-4 md:size-5" />}
          back={{ label: "Back to CRMs", onFallback: () => navigate({ to: "/" }) }}
        />
        <Main>
          <GeneralError
            error={new Error(loaderError ?? "Failed to load CRM")}
            minimal
            mode="inline"
            reset={() => void router.invalidate()}
          />
        </Main>
      </>
    );
  }

  return (
    <CrmPageContent
      crm={crm}
      crmId={params.crmId}
      search={search}
      initialObjectId={params.objectId}
    />
  );
}
