import { createFileRoute } from "@tanstack/react-router";
import { GeneralError } from "@mochi/common";
import { CrmsListPage } from "@/features/crms/pages";

export const Route = createFileRoute("/_authenticated/")({
  component: CrmsListPage,
  errorComponent: ({ error }) => <GeneralError error={error} />,
});
