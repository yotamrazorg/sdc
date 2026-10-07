import { defineConfig } from "@playwright/test";

// catalog-fe (SDC frontend web server) HTTP port; matches FE_HTTP_PORT of the lifecycle.
const fePort = process.env.FE_HTTP_PORT || "8181";

export default defineConfig({
  testDir: ".",
  testMatch: /.*\.spec\.ts/,
  timeout: 30000,
  retries: 1,
  workers: 1,
  use: {
    baseURL: `http://localhost:${fePort}`,
    headless: true,
    screenshot: "on",
    video: "retain-on-failure",
    trace: "retain-on-failure",
  },
  reporter: [
    ["list"],
    [
      "json",
      {
        outputFile: `${process.env.MCODE_DIR}/fe_testing/playwright-results.json`,
      },
    ],
  ],
});
