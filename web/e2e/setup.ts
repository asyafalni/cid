import { execSync } from 'node:child_process';
import { mkdtempSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { spawn } from 'node:child_process';

// Seeds e2e/datasets/demo through the real CLI: three frames (two
// identical — the preview dedup on display), a README, two releases,
// previews built. Idempotent: an existing seeded dataset is left alone.
export default function setup() {
  const here = dirname(fileURLToPath(import.meta.url));
  const cid = resolve(here, '../../zig-out/bin/cid');
  const env = {
    ...process.env,
    CID_DB: 'host=127.0.0.1 port=5433 user=cid password=cid-test dbname=cid_test',
    CID_S3_ENDPOINT: 'http://127.0.0.1:8333',
    CID_S3_ACCESS_KEY: 'cid-test-key',
    CID_S3_SECRET_KEY: 'cid-test-secret',
    CID_S3_BUCKET: 'cid-test',
    CID_TOKEN: 'e2e-dashboard-token',
    CID_SERVER: 'http://127.0.0.1:7177',
  };
  const run = (cmd: string, cwd?: string) =>
    execSync(cmd, { env, cwd, stdio: ['ignore', 'pipe', 'pipe'] })
      .toString()
      .trim();

  // A serve must be up for the CLI; playwright's webServer starts it
  // before tests but after globalSetup, so run our own briefly.
  const serve = spawn(cid, ['admin', 'serve', '--port', '7178'], { env, stdio: 'ignore' });
  env.CID_SERVER = 'http://127.0.0.1:7178';
  try {
    execSync('sleep 1');
    const already = run(
      `curl -s http://127.0.0.1:7178/v0/datasets -H "Authorization: Bearer e2e-dashboard-token"`,
    );
    if (already.includes('e2e/datasets/demo')) return;

    const dir = mkdtempSync(join(tmpdir(), 'cid-e2e-'));
    run(
      `ffmpeg -nostdin -loglevel error -f lavfi -i testsrc=size=200x150:rate=1 -frames:v 1 -y ${dir}/img-a.png`,
    );
    run(
      `ffmpeg -nostdin -loglevel error -f lavfi -i testsrc2=size=200x150:rate=1 -frames:v 1 -y ${dir}/img-b.png`,
    );
    writeFileSync(join(dir, 'README.txt'), 'the e2e dataset\n');
    run(`${cid} init cid@127.0.0.1:e2e/datasets/demo --git g@h:e2e.git`, dir);
    run(`${cid} add .`, dir);
    run(`${cid} commit -m "first frames"`, dir);
    run(`${cid} push`, dir);
    run(`${cid} tag v1.0.0`, dir);
    writeFileSync(join(dir, 'notes.txt'), 'a second version\n');
    run(`${cid} commit -am "notes"`, dir);
    run(`${cid} push`, dir);
    run(`${cid} tag v1.1.0`, dir);
    run(`${cid} admin previews`); // sniff + thumbs for the pngs
  } finally {
    serve.kill();
  }
}
