// mroom template (copied once by `mroom init`; the app owns it from then on).
//
// A vitest reporter that records how long each test file took on this runner, so the unit-test
// shards in .github/workflows/ci-frontend.yml can be balanced on measured times rather than guesses.
//
// Vitest loads a reporter through Vite, and Vite only serves files under the project (`server.fs.allow`),
// so copy it under the frontend folder first, into node_modules/.cache/ so the copy is never committed.
// From the frontend folder:
//
//   mkdir -p node_modules/.cache
//   cp "$(git rev-parse --show-toplevel)/.github/scripts/vitest-file-times.mjs" node_modules/.cache/
//   vitest run --reporter=default --reporter=./node_modules/.cache/vitest-file-times.mjs
//
// It writes node_modules/.cache/vitest-file-times.json, or the path in $VITEST_FILE_TIMES_OUTPUT: one
// row per file with the phases vitest reports (environment, prepare, collect, setup, run) in
// milliseconds and their sum, slowest first. When $GITHUB_STEP_SUMMARY is set it also appends a short
// table of the slowest files and the shard total to the job summary.
import { appendFileSync, mkdirSync, writeFileSync } from "node:fs";
import { dirname, relative } from "node:path";

const round = (ms) => Math.round(ms ?? 0);

export default class FileTimesReporter {
  onInit(ctx) {
    this.root = ctx.config.root;
  }

  // onTestRunEnd, not onFinished: vitest 4 removed onFinished. This hook exists from vitest 3.
  onTestRunEnd(testModules = []) {
    const rows = testModules
      .map((testModule) => {
        const diagnostic = testModule.diagnostic();
        const phases = {
          environment: round(diagnostic.environmentSetupDuration),
          prepare: round(diagnostic.prepareDuration),
          collect: round(diagnostic.collectDuration),
          setup: round(diagnostic.setupDuration),
          run: round(diagnostic.duration),
        };
        return {
          file: relative(this.root, testModule.moduleId),
          tests: [...testModule.children.allTests()].length,
          state: testModule.state(),
          ...phases,
          total: Object.values(phases).reduce((sum, ms) => sum + ms, 0),
        };
      })
      .sort((a, b) => b.total - a.total);

    const output =
      process.env.VITEST_FILE_TIMES_OUTPUT || "node_modules/.cache/vitest-file-times.json";
    mkdirSync(dirname(output), { recursive: true });
    writeFileSync(output, `${JSON.stringify(rows, null, 2)}\n`);

    const summary = process.env.GITHUB_STEP_SUMMARY;
    if (!summary) return;

    const sum = (key) => rows.reduce((total, row) => total + row[key], 0);
    const seconds = (ms) => (ms / 1000).toFixed(1);
    const lines = [
      `### Unit-test file times`,
      ``,
      `${rows.length} files, ${sum("tests")} tests, ${seconds(sum("total"))} s summed ` +
        `(environment ${seconds(sum("environment"))}, collect ${seconds(sum("collect"))}, ` +
        `setup ${seconds(sum("setup"))}, run ${seconds(sum("run"))}).`,
      ``,
      `| file | tests | total s | collect s | run s |`,
      `|---|---:|---:|---:|---:|`,
      ...rows
        .slice(0, 15)
        .map(
          (row) =>
            `| ${row.file} | ${row.tests} | ${seconds(row.total)} | ${seconds(row.collect)} | ${seconds(row.run)} |`,
        ),
      ``,
    ];
    appendFileSync(summary, `${lines.join("\n")}\n`);
  }
}
