// Playwright check of the dispatch Plan Board: renders the page, extracts every
// plan card's session boxes / states / edges / contradictions, optionally asserts.
//
//   node board-check.js <out.png> ['{"plan":"id","sessions":{"name":"state-substr"},"minEdges":1}']
//
// With no expectations: smoke mode — asserts the page renders and lists what it found.
// URL via CC_BOARD_URL (default http://100.100.213.79:7822/plans.html).
// Needs `npm i playwright` wherever it runs (laptop is fine); run-tests.sh skips it
// when playwright or the board is unreachable.
let chromium;
try { ({ chromium } = require("playwright")); }
catch { ({ chromium } = require(require("path").join(process.cwd(), "node_modules", "playwright"))); }

(async () => {
  const [out, expectRaw] = process.argv.slice(2);
  const expect = expectRaw ? JSON.parse(expectRaw) : null;
  const url = process.env.CC_BOARD_URL || "http://100.100.213.79:7822/plans.html";
  const browser = await chromium.launch();
  const page = await browser.newPage({ viewport: { width: 1280, height: 900 } });
  await page.goto(url, { waitUntil: "networkidle" });
  await page.waitForSelector(".plan, .empty", { timeout: 15000 });
  await page.waitForTimeout(1000); // edge SVG draws on rAF after layout

  const data = await page.evaluate(() => {
    const plans = [];
    for (const card of document.querySelectorAll(".plan")) {
      const sessions = {};
      for (const box of card.querySelectorAll(".sess")) {
        const name = box.querySelector(".nm")?.textContent ?? "?";
        sessions[name] = {
          state: box.querySelector(".st")?.textContent ?? "?",
          meta: box.querySelector(".meta")?.textContent ?? "",
        };
      }
      plans.push({
        title: card.querySelector("h2 span")?.textContent ?? "?",
        sessions,
        edges: card.querySelectorAll("svg.edges > line, svg.edges > path").length,
        contradictions: [...card.querySelectorAll(".contras div.row")].map((d) => d.textContent),
      });
    }
    return plans;
  });

  let failed = 0;
  const check = (label, cond) => {
    console.log((cond ? "  ok: " : "  FAIL: ") + label);
    if (!cond) failed++;
  };

  if (!expect) {
    check("board rendered", true);
    console.log(`  plans on board: ${data.length}`);
    for (const p of data)
      console.log(`  ${p.title}: ${Object.entries(p.sessions).map(([n, s]) => `${n}=${s.state}`).join(" · ")}` +
                  ` · ${p.edges} edge(s) · ${p.contradictions.length} contradiction line(s)`);
  } else {
    const plan = data.find((p) => p.title === expect.plan);
    check(`plan card '${expect.plan}' rendered`, !!plan);
    if (plan) {
      for (const [name, stateSub] of Object.entries(expect.sessions || {})) {
        const s = plan.sessions[name];
        check(`box '${name}' present`, !!s);
        if (s) check(`'${name}' state ~'${stateSub}' (got '${s.state}')`, s.state.includes(stateSub));
      }
      check(`edges >= ${expect.minEdges ?? 0} (got ${plan.edges})`, plan.edges >= (expect.minEdges ?? 0));
      console.log("  contradictions:", JSON.stringify(plan.contradictions));
    }
  }
  if (out) await page.screenshot({ path: out, fullPage: true });
  await browser.close();
  console.log(failed ? `BOARD CHECK: ${failed} FAILURES` : "BOARD CHECK: ALL OK");
  process.exit(failed ? 1 : 0);
})();
