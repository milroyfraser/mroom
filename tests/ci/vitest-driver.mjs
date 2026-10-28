// vitest-driver.mjs <reporter.mjs>: runs the vitest reporter's hooks on two fake test modules, shaped like
// vitest's TestModule (vitest 3 and later), then prints each row it wrote as file:tests:total:state.
import { readFileSync } from "node:fs";
import { pathToFileURL } from "node:url";

const { default: Reporter } = await import(pathToFileURL(process.argv[2]).href);

const testModule = (id, run, tests) => ({
  moduleId: `/repo/web/${id}`,
  state: () => "passed",
  diagnostic: () => ({
    environmentSetupDuration: 10,
    prepareDuration: 1,
    collectDuration: 20,
    setupDuration: 5,
    duration: run,
  }),
  children: {
    *allTests() {
      for (let i = 0; i < tests; i++) yield {};
    },
  },
});

const reporter = new Reporter();
reporter.onInit({ config: { root: "/repo/web" } });
reporter.onTestRunEnd([testModule("src/a.test.ts", 100, 2), testModule("src/b.test.ts", 300, 3)]);

const rows = JSON.parse(readFileSync(process.env.VITEST_FILE_TIMES_OUTPUT, "utf8"));
console.log(rows.map((row) => `${row.file}:${row.tests}:${row.total}:${row.state}`).join(" "));
