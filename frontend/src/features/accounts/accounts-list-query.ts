import type { SortOrder } from "@/shared/lib/table-sort";

/** Backend applyAccountStatusFilter("active"): enabled, auth active, not cooldown/recovery/quota-exhausted. */
export const DEFAULT_ACCOUNT_STATUS_FILTER = "active";

export type AccountListQueryInput = {
  page: number;
  pageSize: number;
  search?: string;
  type?: string;
  status?: string;
  egress?: string;
  renewal?: string;
  risk?: string;
  agreement?: string;
  association?: string;
  provider?: "grok_build" | "grok_web" | "grok_console";
  sortBy?: string;
  sortOrder?: SortOrder;
};

export function accountListQuery(input: AccountListQueryInput): URLSearchParams {
  const query = new URLSearchParams({ page: String(input.page), pageSize: String(input.pageSize) });
  if (input.search) query.set("search", input.search);
  if (input.type) query.set("type", input.type);
  if (input.status) query.set("status", input.status);
  if (input.egress) query.set("egress", input.egress);
  if (input.renewal) query.set("renewal", input.renewal);
  if (input.risk) query.set("risk", input.risk);
  if (input.agreement) query.set("agreement", input.agreement);
  if (input.association) query.set("association", input.association);
  if (input.sortBy && input.sortOrder) {
    query.set("sortBy", input.sortBy);
    query.set("sortOrder", input.sortOrder);
  }
  if (input.provider) query.set("provider", input.provider);
  return query;
}
