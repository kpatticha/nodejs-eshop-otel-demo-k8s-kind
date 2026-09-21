// Load generator for the demo scenarios.
//
// Drives steady HTTP traffic at every configured target so the kubeletstats
// pod and container metrics carry non-zero CPU, memory and network values
// instead of flat-lining at zero. No OpenTelemetry code here either.
//
// Configuration (env):
//   TARGETS        comma-separated URLs; one request per URL per tick
//   INTERVAL_MS    milliseconds between ticks (default 1000)
//   REPORT_MS      milliseconds between summary log lines (default 30000)
//   EXIT_AFTER_MS  run for this long, then exit 0 (default: run forever)
//
// EXIT_AFTER_MS is what makes this usable as a Job or CronJob container: the
// pod does real work, completes, and goes away, which is where pod churn
// comes from.

const TARGETS = (process.env.TARGETS || 'http://frontend:8080/')
  .split(',')
  .map((t) => t.trim())
  .filter(Boolean);
const INTERVAL_MS = Number(process.env.INTERVAL_MS) || 1000;
const REPORT_MS = Number(process.env.REPORT_MS) || 30000;
const EXIT_AFTER_MS = Number(process.env.EXIT_AFTER_MS) || 0;

const stats = new Map(TARGETS.map((t) => [t, { ok: 0, failed: 0 }]));

async function hit(url) {
  const entry = stats.get(url);
  try {
    const res = await fetch(url);
    // Read the body so the bytes actually cross the pod's network interface.
    await res.arrayBuffer();
    if (res.ok) {
      entry.ok += 1;
    } else {
      entry.failed += 1;
    }
  } catch (err) {
    entry.failed += 1;
  }
}

console.log(`loadgen: one request to each of ${TARGETS.length} target(s) every ${INTERVAL_MS}ms`);
for (const target of TARGETS) {
  console.log(`  ${target}`);
}

setInterval(() => {
  for (const target of TARGETS) {
    hit(target);
  }
}, INTERVAL_MS);

function summarise() {
  return [...stats.entries()]
    .map(([url, s]) => `${url} ok=${s.ok} failed=${s.failed}`)
    .join(' | ');
}

setInterval(() => {
  console.log(summarise());
}, REPORT_MS);

if (EXIT_AFTER_MS > 0) {
  console.log(`loadgen: will exit after ${EXIT_AFTER_MS}ms`);
  setTimeout(() => {
    console.log(summarise());
    console.log('loadgen: done');
    process.exit(0);
  }, EXIT_AFTER_MS);
}
