import { execSync } from 'node:child_process';
import { createHash, randomBytes } from 'node:crypto';
import { mkdtempSync, readFileSync, statSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { spawn } from 'node:child_process';

// Seeds two datasets the way their real producers would:
//   e2e/datasets/demo  — a file dataset through the CLI (frames, README,
//                        two releases).
//   e2e/datasets/boxes — an annotated dataset the platform's way: bytes
//                        through check-hashes + register-items, revision
//                        rows inserted directly (UUIDv7, like cid_writer),
//                        sealed by the server's commit, tagged v1.0.0.
// Idempotent: a dataset that already exists is left alone.

const here = dirname(fileURLToPath(import.meta.url));
const cid = resolve(here, '../../zig-out/bin/cid');
const compose = resolve(here, '../../docker-compose.test.yml');
const token = 'e2e-dashboard-token';

const env = {
  ...process.env,
  CID_DB: 'host=127.0.0.1 port=5433 user=cid password=cid-test dbname=cid_test',
  CID_S3_ENDPOINT: 'http://127.0.0.1:8333',
  CID_S3_ACCESS_KEY: 'cid-test-key',
  CID_S3_SECRET_KEY: 'cid-test-secret',
  CID_TOKEN: token,
  CID_SERVER: 'http://127.0.0.1:7178',
};

function run(cmd: string, cwd?: string): string {
  return execSync(cmd, { env, cwd, stdio: ['ignore', 'pipe', 'pipe'] })
    .toString()
    .trim();
}

function api(method: string, path: string, body?: unknown): unknown {
  const data = body === undefined ? '' : `--data '${JSON.stringify(body).replace(/'/g, "'\\''")}'`;
  const out = run(
    `curl -s -X ${method} ${data} -H "Authorization: Bearer ${token}" -H "content-type: application/json" http://127.0.0.1:7178${path}`,
  );
  return out ? JSON.parse(out) : {};
}

function psqlValue(sql: string): string {
  return execSync(`docker compose -f ${compose} exec -T timescaledb psql -tA -U cid -d cid_test -c "${sql}"`, {
    stdio: ['ignore', 'pipe', 'pipe'],
  })
    .toString()
    .trim();
}

function psql(sql: string) {
  execSync(`docker compose -f ${compose} exec -T timescaledb psql -q -U cid -d cid_test -v ON_ERROR_STOP=1`, {
    input: sql,
    stdio: ['pipe', 'pipe', 'pipe'],
  });
}

// UUIDv7, strictly ascending the way cid_writer mints them: the counter
// rides the bits right after the version, so two in one millisecond
// still order.
let uuidSeq = 0;
function uuid7(): string {
  const ms = BigInt(Date.now());
  const bytes = Buffer.concat([Buffer.alloc(6), randomBytes(10)]);
  bytes.writeUIntBE(Number(ms >> 8n), 0, 5);
  bytes[5] = Number(ms & 0xffn);
  uuidSeq = (uuidSeq + 1) & 0x3ff;
  bytes[6] = 0x70 | ((uuidSeq >> 6) & 0x0f);
  bytes[7] = ((uuidSeq & 0x3f) << 2) | (bytes[7] & 0x03);
  bytes[8] = (bytes[8] & 0x3f) | 0x80;
  const hex = bytes.toString('hex');
  return `${hex.slice(0, 8)}-${hex.slice(8, 12)}-${hex.slice(12, 16)}-${hex.slice(16, 20)}-${hex.slice(20)}`;
}

function seedDemo(dir: string) {
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
}

function seedBoxes(dir: string) {
  const name = 'e2e/datasets/boxes';
  const created = api('POST', '/v0/datasets', {
    name,
    kind: 'annotated',
    git_url: 'g@h:boxes.git',
  }) as { dataset_id?: string };
  const datasetId = created.dataset_id;
  if (!datasetId) throw new Error('could not create the boxes dataset');

  const png = join(dir, 'street.png');
  run(
    `ffmpeg -nostdin -loglevel error -f lavfi -i testsrc=size=200x150:rate=1 -frames:v 1 -y ${png}`,
  );
  const bytes = readFileSync(png);
  const hash = createHash('sha256').update(bytes).digest('hex');
  const size = statSync(png).size;

  const check = api('POST', `/v0/datasets/${name}/-/check-hashes`, { hashes: [hash] }) as {
    missing: { hash: string; url: string }[];
  };
  for (const m of check.missing) {
    run(`curl -s -X PUT --data-binary @${png} '${m.url}'`);
  }
  api('POST', `/v0/datasets/${name}/-/register-items`, {
    items: [{ hash, size, media_type: 'image/png', width: 200, height: 150 }],
  });
  api('POST', `/v0/datasets/${name}/-/policy`, {
    version: 'p1',
    body: { rule: 'label every person and vehicle' },
  });

  // The platform's half: revision rows, directly, under UUIDv7 ids —
  // then the server's commit seals them.
  const itemId = uuid7();
  const rev1 = uuid7();
  const annPerson = uuid7();
  const annVehicle = uuid7();
  const rev2 = uuid7();
  const rev3 = uuid7();
  psql(`
    INSERT INTO item_revisions (rev_id, ts, dataset_id, branch, path, op, item_id, item_hash, split, author)
    VALUES ('${rev1}'::uuid, now(), '${datasetId}'::uuid, 'main', 'frames/street.png', 'add',
            '${itemId}'::uuid, decode('${hash}', 'hex'), 'train', 'agent:annotator');
    INSERT INTO dataset_items (item_id, dataset_id)
    VALUES ('${itemId}'::uuid, '${datasetId}'::uuid) ON CONFLICT (item_id) DO NOTHING;
    INSERT INTO annotation_revisions (rev_id, ts, dataset_id, branch, annotation_id, item_id, op, kind, class, geometry, author, policy_ver)
    VALUES ('${rev2}'::uuid, now(), '${datasetId}'::uuid, 'main', '${annPerson}'::uuid, '${itemId}'::uuid,
            'create', 'box', 'person', '{"x":20,"y":15,"w":60,"h":50}'::jsonb, 'agent:annotator', 'p1'),
           ('${rev3}'::uuid, now(), '${datasetId}'::uuid, 'main', '${annVehicle}'::uuid, '${itemId}'::uuid,
            'create', 'box', 'vehicle', '{"x":110,"y":40,"w":70,"h":80}'::jsonb, 'agent:annotator', 'p1');
  `);

  api('POST', `/v0/datasets/${name}/-/commit`, {
    message: 'first labelled frame',
    author: 'agent:annotator',
  });
  api('POST', `/v0/datasets/${name}/-/tag`, { name: 'v1.0.0' });
}

// v1.1.0 of the boxes dataset: the person box moves, the platform's way
// — an `update` revision on the same annotation_id — so Compare has a
// changed box to show before and after on the same image.
function seedBoxesMoved() {
  const name = 'e2e/datasets/boxes';
  const datasetId = psqlValue(`SELECT dataset_id FROM datasets WHERE name = '${name}'`);
  const head = api('GET', `/v0/datasets/${name}/-/head`) as { commit: string };
  const state = api('GET', `/v0/datasets/${name}/-/state/${head.commit}`) as {
    annotations: { id: string; item_id: string; class: string }[];
  };
  const person = state.annotations.find((a) => a.class === 'person');
  if (!person) throw new Error('the boxes dataset has no person box to move');
  const rev = uuid7();
  psql(`
    INSERT INTO annotation_revisions (rev_id, ts, dataset_id, branch, annotation_id, item_id, op, kind, class, geometry, author, policy_ver)
    VALUES ('${rev}'::uuid, now(), '${datasetId}'::uuid, 'main', '${person.id}'::uuid, '${person.item_id}'::uuid,
            'update', 'box', 'person', '{"x":45,"y":30,"w":60,"h":50}'::jsonb, 'user:reviewer', 'p1');
  `);
  api('POST', `/v0/datasets/${name}/-/commit`, {
    message: 'reviewer moved the person box',
    author: 'user:reviewer',
  });
  api('POST', `/v0/datasets/${name}/-/tag`, { name: 'v1.1.0' });
}

export default function setup() {
  // A serve must be up for the CLI and the API; playwright's webServer
  // starts its own before tests but after globalSetup, so run one briefly.
  const serve = spawn(cid, ['admin', 'serve', '--port', '7178'], { env, stdio: 'ignore' });
  try {
    execSync('sleep 1');
    const already = run(
      `curl -s http://127.0.0.1:7178/v0/datasets -H "Authorization: Bearer ${token}"`,
    );
    const dir = mkdtempSync(join(tmpdir(), 'cid-e2e-'));
    if (!already.includes('e2e/datasets/demo')) seedDemo(dir);
    if (!already.includes('e2e/datasets/boxes')) seedBoxes(dir);
    const boxReleases = run(
      `curl -s http://127.0.0.1:7178/v0/datasets/e2e/datasets/boxes/-/releases -H "Authorization: Bearer ${token}"`,
    );
    if (!boxReleases.includes('"v1.1.0"')) seedBoxesMoved();
    // The fake GitLab's user may read the boxes dataset and nothing else,
    // granted the way an owner would in the dashboard. Idempotent.
    psql(`
      INSERT INTO accounts (account_id, display_name, source) VALUES ('gitlab:4242', 'Rhea Reviewer', 'gitlab')
        ON CONFLICT (account_id) DO NOTHING;
      INSERT INTO access (dataset_id, account_id, level, source)
        SELECT dataset_id, 'gitlab:4242', 'read', 'dashboard' FROM datasets WHERE name = 'e2e/datasets/boxes'
        ON CONFLICT (dataset_id, account_id) DO NOTHING;
      INSERT INTO accounts (account_id, display_name, source) VALUES ('gitlab:5151', 'Olu Owner', 'gitlab')
        ON CONFLICT (account_id) DO NOTHING;
      INSERT INTO access (dataset_id, account_id, level, source)
        SELECT dataset_id, 'gitlab:5151', 'maintain', 'dashboard' FROM datasets WHERE name = 'e2e/datasets/boxes'
        ON CONFLICT (dataset_id, account_id) DO NOTHING;
    `);
    run(`${cid} admin previews`); // sniff + thumbs for every new png
  } finally {
    serve.kill();
  }
}
