import assert from "node:assert/strict";
import { describe, it } from "node:test";

import { accountListQuery, DEFAULT_ACCOUNT_STATUS_FILTER } from "./accounts-list-query.ts";

describe("account list query", () => {
  it("defaults eligible status to backend active", () => {
    assert.equal(DEFAULT_ACCOUNT_STATUS_FILTER, "active");
  });

  it("includes status=active when the eligible default is passed", () => {
    const query = accountListQuery({ page: 1, pageSize: 20, status: DEFAULT_ACCOUNT_STATUS_FILTER, provider: "grok_web" });
    assert.equal(query.get("status"), "active");
    assert.equal(query.get("page"), "1");
    assert.equal(query.get("pageSize"), "20");
    assert.equal(query.get("provider"), "grok_web");
  });

  it("omits status for Show all (empty filter)", () => {
    const query = accountListQuery({ page: 1, pageSize: 20, status: "" });
    assert.equal(query.get("status"), null);
  });
});
