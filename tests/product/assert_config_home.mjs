// Shared HOME/.thin acceptance for fixtures: only config.json and an optional
// private discovery index may exist. Nothing here runs at import time.
//
// Without a checkpoint argument the index must stay completely empty, which is
// what headless fixtures expect. An interactive owner that actually published
// state passes {project, id} and the one real index record is validated field by
// field; it is only a discovery hint, never authority to replay a session.

import {createHash} from 'node:crypto';
import {lstat, readFile, readdir, realpath} from 'node:fs/promises';
import {isAbsolute, join} from 'node:path';
import assert from 'node:assert/strict';

// Exactly the keys daemon/registry.zig encodes; anything else means the record
// came from somewhere other than the real producer.
const INDEX_KEYS = [
  'v', 'id', 'project', 'project_key', 'owner', 'owner_instance',
  'endpoint', 'state', 'updated_ms', 'generation', 'pid',
].sort();
const MAX_INDEX_BYTES = 16 * 1024;
const MAX_STATE_BYTES = 32;
const MAX_UNIX_PATH_BYTES = 107;

/// Registry.projectKey: lowercase hex of the first 16 digest bytes.
function projectKey(project) {
  return createHash('sha256').update(project).digest('hex').slice(0, 32);
}

async function assertIndexEntry(root, key, checkpoint, canonical) {
  const dir = join(root, 'session-index', key);
  const keyInfo = await lstat(dir);
  assert(keyInfo.isDirectory() && !keyInfo.isSymbolicLink(), `${dir}: not a real directory`);
  assert.equal(keyInfo.mode & 0o777, 0o700, `${dir}: mode`);

  const expected = `${checkpoint.id}.json`;
  assert.deepEqual(await readdir(dir), [expected], `${dir}: unexpected index contents`);

  const path = join(dir, expected);
  const info = await lstat(path);
  assert(info.isFile() && !info.isSymbolicLink(), `${path}: not a real file`);
  assert.equal(info.mode & 0o777, 0o600, `${path}: mode`);
  assert(info.size > 0 && info.size <= MAX_INDEX_BYTES, `${path}: size ${info.size}`);

  const record = JSON.parse(await readFile(path, 'utf8'));
  assert.deepEqual(Object.keys(record).sort(), INDEX_KEYS, `${path}: unexpected fields`);
  assert.equal(record.v, 1, `${path}: version`);
  assert.equal(record.id, checkpoint.id, `${path}: id`);
  assert.equal(record.project, canonical, `${path}: project`);
  assert.equal(record.project_key, key, `${path}: project_key`);
  assert.equal(record.owner, 'foreground', `${path}: owner`);
  assert.match(record.owner_instance, /^[0-9a-f]{1,32}$/, `${path}: owner_instance`);
  assert(typeof record.endpoint === 'string' && record.endpoint.length > 0, `${path}: endpoint`);
  assert(isAbsolute(record.endpoint), `${path}: endpoint is not absolute`);
  assert(Buffer.byteLength(record.endpoint) <= MAX_UNIX_PATH_BYTES, `${path}: endpoint too long`);
  // Histories keep the discovery hint they published; closed/live is probed live
  // and must not be asserted here.
  assert(typeof record.state === 'string', `${path}: state`);
  assert(record.state.length > 0 && record.state.length <= MAX_STATE_BYTES, `${path}: state length`);
  assert.match(record.state, /^[\x21-\x7e]+$/, `${path}: state bytes`);
  assert(Number.isInteger(record.pid) && record.pid > 0 && record.pid <= 0xffffffff, `${path}: pid`);
  assert(Number.isSafeInteger(record.generation) && record.generation > 0, `${path}: generation`);
  assert(Number.isInteger(record.updated_ms) && record.updated_ms >= 0, `${path}: updated_ms`);
  return record;
}

async function assertCheckpointFile(canonical, id) {
  const dir = join(canonical, '.thin', 'sessions');
  const dirInfo = await lstat(dir);
  assert(dirInfo.isDirectory() && !dirInfo.isSymbolicLink(), `${dir}: not a real directory`);
  const path = join(dir, `${id}.session`);
  const info = await lstat(path);
  assert(info.isFile() && !info.isSymbolicLink(), `${path}: not a real file`);
  assert.equal(info.mode & 0o777, 0o600, `${path}: mode`);
  assert(info.size > 0, `${path}: empty checkpoint`);
}

export async function assertConfigHome(home, checkpoint = null) {
  const root = join(home, '.thin');
  const info = await lstat(root);
  assert(info.isDirectory() && !info.isSymbolicLink(), `${root}: not a real directory`);
  // The optional index is checked below; every other entry must be config.json.
  assert.deepEqual((await readdir(root)).filter(name => name !== 'session-index'), ['config.json'], `${root}: unexpected home state`);

  if (checkpoint != null) {
    assert(typeof checkpoint === 'object', 'checkpoint: not an object');
    assert(typeof checkpoint.project === 'string' && checkpoint.project.length > 0, 'checkpoint: project');
    assert.match(checkpoint.id, /^[0-9a-f]{32}$/, 'checkpoint: id');
  }

  const indexPath = join(root, 'session-index');
  let index;
  try { index = await lstat(indexPath); } catch (error) {
    if (error.code !== 'ENOENT') throw error;
    assert(checkpoint == null, '.thin/session-index: published index missing');
    return;
  }
  assert(index.isDirectory() && !index.isSymbolicLink(), '.thin/session-index: not a real directory');
  assert.equal(index.mode & 0o777, 0o700, '.thin/session-index: mode');

  if (checkpoint == null) {
    for (const key of await readdir(indexPath, {withFileTypes:true})) {
      assert(key.isDirectory() && !key.isSymbolicLink(), `.thin/session-index/${key.name}: not a real directory`);
      const dir = join(indexPath, key.name);
      assert.equal((await lstat(dir)).mode & 0o777, 0o700, `${dir}: mode`);
      for (const name of await readdir(dir)) assert.fail(`${dir}/${name}: session data persisted`);
    }
    return;
  }

  const canonical = await realpath(checkpoint.project);
  const key = projectKey(canonical);
  assert.deepEqual(await readdir(indexPath), [key], '.thin/session-index: unexpected key directories');
  await assertIndexEntry(root, key, checkpoint, canonical);
  await assertCheckpointFile(canonical, checkpoint.id);
}
