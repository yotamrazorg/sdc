import { test, expect } from "@playwright/test";

const JSON_HEADERS = { Accept: "application/json" };
const stubBePort = Number(process.env.STUB_BE_PORT || 18080);

test.describe("healthCheck (stand-in BE: FE UP / BE DOWN)", () => {
  test("returns 500 with JSON listing FE UP and BE DOWN", async ({ request }) => {
    // The first answer after start can be `500 {}`; wait for the monitoring probe to populate it.
    await expect
      .poll(
        async () => {
          const res = await request.get("/sdc1/rest/healthCheck", { headers: JSON_HEADERS });
          const text = await res.text();
          try {
            return Array.isArray(JSON.parse(text).componentsInfo);
          } catch {
            return false;
          }
        },
        { timeout: 20000, intervals: [1000] }
      )
      .toBe(true);

    const res = await request.get("/sdc1/rest/healthCheck", { headers: JSON_HEADERS });
    expect(res.status()).toBe(500);
    expect(res.headers()["content-type"]).toContain("application/json");
    const body = await res.json();

    expect(body.componentsInfo.map((c: any) => c.healthCheckComponent)).toEqual([
      "FE",
      "BE",
      "JANUSGRAPH",
      "CASSANDRA",
      "DE",
      "ON_BOARDING",
      "CATALOG_FACADE_MS",
    ]);
    const byName = (n: string) => body.componentsInfo.find((c: any) => c.healthCheckComponent === n);
    expect(byName("FE").healthCheckStatus).toBe("UP");
    expect(byName("FE").description).toBe("OK");
    expect(byName("FE").version).toMatch(/^\d+\.\d+\.\d+/);
    expect(byName("BE").healthCheckStatus).toBe("DOWN");
    for (const n of ["JANUSGRAPH", "CASSANDRA", "DE", "ON_BOARDING", "CATALOG_FACADE_MS"]) {
      expect(byName(n).healthCheckStatus).toBe("UNKNOWN");
    }
    expect(body.sdcVersion).toBe("UNKNOWN");
    expect(body.siteMode).toBe("UNKNOWN");
  });
});

test.describe("config/ui/workspace", () => {
  test("returns 200 JSON with the workspace menu configuration", async ({ request }) => {
    const res = await request.get("/sdc1/rest/config/ui/workspace");
    expect(res.status()).toBe(200);
    expect(res.headers()["content-type"]).toContain("application/json");
    const body = await res.json();
    expect(body).toHaveProperty("workspaceMenuConfiguration");
    const vfc = body.workspaceMenuConfiguration.VFC;
    expect(Array.isArray(vfc)).toBe(true);
    expect(vfc[0]).toEqual({
      text: "General",
      action: "onMenuItemPressed",
      state: "workspace.general",
    });
    const states = Object.fromEntries(vfc.map((i: any) => [i.text, i.state]));
    expect(states["Deployment Artifact"]).toBe("workspace.deployment_artifacts");
    expect(states["Information Artifact"]).toBe("workspace.information_artifacts");
    expect(states["TOSCA Artifacts"]).toBe("workspace.tosca_artifacts");
  });
});

test.describe("config/ui/plugins", () => {
  test("returns 200 JSON array of plugins, none online", async ({ request }) => {
    const res = await request.get("/sdc1/rest/config/ui/plugins");
    expect(res.status()).toBe(200);
    expect(res.headers()["content-type"]).toContain("application/json");
    const body = await res.json();
    expect(Array.isArray(body)).toBe(true);
    expect(body.length).toBeGreaterThan(1);
    const ids = body.map((p: any) => p.pluginId);
    expect(ids[0]).toBe("POLICY");
    expect(ids).toContain("POLICY_LIST");
    const policy = body[0];
    expect(policy.pluginStateUrl).toBe("policy");
    expect(policy.pluginDisplayOptions.tab.displayName).toBe("POLICY");
    expect(policy.pluginDisplayOptions.tab.displayRoles).toEqual(["DESIGNER"]);
    for (const p of body) {
      expect(p.isOnline).toBe(false);
    }
  });
});

test.describe("configmgr/get", () => {
  test("returns 200 JSON with the run configuration", async ({ request }) => {
    const res = await request.get("/sdc1/rest/configmgr/get");
    expect(res.status()).toBe(200);
    expect(res.headers()["content-type"]).toContain("application/json");
    const body = await res.json();
    expect(body.feFqdn).toBe("sdc-FE");
    expect(body.beHost).toBe("127.0.0.1");
    expect(body.beHttpPort).toBe(stubBePort);
    expect(body.beSslPort).toBe(8443);
    expect(body.healthCheckSocketTimeoutInMs).toBe(5000);
    expect(body.healthCheckIntervalInSeconds).toBe(5);
    expect(body.healthStatusExclude).toEqual([
      "DE",
      "DMAAP",
      "DCAE",
      "DMAAP_PRODUCER",
      "PORTAL",
      "CATALOG_FACADE_MS",
      "External API",
    ]);
    expect(body.systemMonitoring).toEqual({
      enabled: true,
      isProxy: true,
      probeIntervalInSeconds: 3,
    });
    expect(body).toHaveProperty("onboarding");
  });
});

test.describe("404 handling", () => {
  test("unknown path inside the context returns the Jetty 404 page", async ({ page }) => {
    const res = await page.goto("/sdc1/nope");
    expect(res!.status()).toBe(404);
    expect(res!.headers()["content-type"]).toContain("text/html");
    await expect(page).toHaveTitle("Error 404 Not Found");
    await expect(page.getByRole("heading", { name: "HTTP ERROR 404 Not Found" })).toBeVisible();
    const row = (label: string) => page.locator("tr", { has: page.locator("th", { hasText: label }) });
    await expect(row("URI:")).toContainText("/sdc1/nope");
    await expect(row("STATUS:")).toContainText("404");
    await expect(row("MESSAGE:")).toContainText("Not Found");
    await expect(row("SERVLET:")).toContainText("default");
  });

  test("unknown path outside the context returns the Jetty 404 page", async ({ page }) => {
    const res = await page.goto("/nope");
    expect(res!.status()).toBe(404);
    await expect(page).toHaveTitle("Error 404 Not Found");
    await expect(page.getByRole("heading", { name: "HTTP ERROR 404 Not Found" })).toBeVisible();
    await expect(page.locator("tr", { hasText: "URI:" })).toContainText("/nope");
  });
});
