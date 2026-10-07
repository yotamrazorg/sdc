import { test, expect } from "@playwright/test";

// The Angular UI (catalog-ui) is intentionally not built in the Foundation milestone,
// so the frontend surface is a static HTML shell with an empty #sdc-app container.
test.describe("catalog-fe redirects", () => {
  test("/ redirects (302) to /sdc1", async ({ request }) => {
    const res = await request.get("/", { maxRedirects: 0 });
    expect(res.status()).toBe(302);
    expect(res.headers()["location"]).toMatch(/\/sdc1$/);
  });

  test("/sdc1 redirects (302) to /sdc1/", async ({ request }) => {
    const res = await request.get("/sdc1", { maxRedirects: 0 });
    expect(res.status()).toBe(302);
    expect(res.headers()["location"]).toMatch(/\/sdc1\/$/);
  });

  test("/sdc1/ serves the HTML shell with 200", async ({ request }) => {
    const res = await request.get("/sdc1/", { maxRedirects: 0 });
    expect(res.status()).toBe(200);
    expect(res.headers()["content-type"]).toContain("text/html");
  });
});

test.describe("catalog-fe shell page", () => {
  test("opening / lands on /sdc1/ with the SDC title and an empty #sdc-app", async ({ page }) => {
    await page.goto("/");
    await expect(page).toHaveURL(/\/sdc1\/$/);
    await expect(page).toHaveTitle("Service Design & Creation");
    const app = page.locator("#sdc-app");
    await expect(app).toHaveCount(1);
    await expect(app).toHaveClass(/sdc-app/);
    await expect(app).toBeEmpty();
  });

  test("shell exposes no interactive elements (UI not built)", async ({ page }) => {
    await page.goto("/sdc1/");
    await expect(page.getByRole("button")).toHaveCount(0);
    await expect(page.getByRole("link")).toHaveCount(0);
    await expect(page.getByRole("textbox")).toHaveCount(0);
  });

  test("/sdc1/portal serves the same shell as /sdc1/", async ({ page, request }) => {
    await page.goto("/sdc1/portal");
    await expect(page).toHaveURL(/\/sdc1\/portal$/);
    await expect(page).toHaveTitle("Service Design & Creation");
    await expect(page.locator("#sdc-app")).toBeEmpty();

    const shell = await (await request.get("/sdc1/")).text();
    const portal = await (await request.get("/sdc1/portal")).text();
    expect(portal).toBe(shell);
  });

  test("shell loads punch-outs_en.js and /favicon.ico", async ({ request }) => {
    const js = await request.get("/sdc1/punch-outs_en.js");
    expect(js.status()).toBe(200);
    const ico = await request.get("/favicon.ico");
    expect(ico.status()).toBe(200);
    expect(ico.headers()["content-type"]).toContain("image/x-icon");
  });

  test("page load raises no unexpected page errors", async ({ page }) => {
    const errors: string[] = [];
    page.on("pageerror", (e) => errors.push(e.message));
    await page.goto("/sdc1/");
    await page.waitForLoadState("networkidle");
    // punch-outs_en.js (onboarding-fe overlay) expects the PunchOutRegistry global that
    // catalog-ui provides. catalog-ui is intentionally not built in this milestone, so that
    // one ReferenceError is the known, expected consequence; anything else is a regression.
    const unexpected = errors.filter((m) => !/PunchOutRegistry is not defined/.test(m));
    expect(unexpected).toEqual([]);
  });
});
