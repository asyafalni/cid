// The MCP door read by the official client (tests/mcp_client.sh): the
// handshake, the tool list, and tools called by name.
import { Client } from '@modelcontextprotocol/sdk/client/index.js';
import { StreamableHTTPClientTransport } from '@modelcontextprotocol/sdk/client/streamableHttp.js';

const [url, token, dataset] = process.argv.slice(2);
const check = (ok, what) => { if (!ok) { console.error('FAIL: ' + what); process.exit(1); } console.log('ok: ' + what); };
const connect = async (bearer) => {
  const transport = new StreamableHTTPClientTransport(new URL(url), {
    requestInit: { headers: bearer ? { Authorization: `Bearer ${bearer}` } : {} },
  });
  const client = new Client({ name: 'cid-test', version: '0' });
  await client.connect(transport);
  return client;
};
const json = (res) => JSON.parse(res.content[0].text);

const client = await connect(token);
check(client.getServerVersion().name === 'cid', 'the handshake names the server');
check(/cid help --json/.test(client.getInstructions() ?? ''), 'its instructions point at the CLI');
const { tools } = await client.listTools();
check(tools.length === 9 && tools.every((t) => t.annotations?.readOnlyHint === true), 'nine tools, all read-only');

const all = await client.callTool({ name: 'list_datasets', arguments: {} });
check(!all.isError && json(all).datasets.some((d) => d.name === dataset), 'list_datasets names the dataset');
const info = await client.callTool({ name: 'get_dataset', arguments: { dataset } });
check(!info.isError && json(info).name === dataset, 'get_dataset at the latest release');
const page = await client.callTool({ name: 'browse_items', arguments: { dataset, version: 'v1.0.0', limit: 1 } });
check(!page.isError && json(page).items.length === 1 && json(page).total === 2, 'browse_items pages a release');
const diff = await client.callTool({ name: 'compare_versions', arguments: { dataset, from: 'v1.0.0', to: 'v1.1.0' } });
check(!diff.isError && json(diff).summary.modified === 1, 'compare_versions counts the change');
const sql = await client.callTool({ name: 'query_sql', arguments: { dataset, sql: 'SELECT count(*) AS n FROM items' } });
check(!sql.isError && json(sql).rows[0].n === 2, 'query_sql answers');
const missing = await client.callTool({ name: 'browse_items', arguments: { dataset, version: 'v9.9.9' } });
check(missing.isError === true && /next/.test(missing.content[0].text), 'a version that does not exist is an error the model can read');
check(await client.ping().then(() => true), 'ping');
await client.close();

// No token: the door says so at once, before any tool.
const refused = await connect(null).then(() => false, (err) => /401|token|Unauthorized/i.test(String(err)));
check(refused, 'no token, no handshake');
