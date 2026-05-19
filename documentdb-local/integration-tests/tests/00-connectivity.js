// Integration tests: connectivity and admin commands.
// Verifies the gateway responds to ping/hello/buildInfo, that databases and
// collections are discoverable via listDatabases/listCollections, and that
// the standard server/db/collection stats commands return the expected shape.

const TEST_FILE = '00-connectivity';
const DB_NAME = 'it_00_connectivity';

function assert(cond, msg) {
  if (!cond) throw new Error(msg || 'assertion failed');
}
function assertEq(actual, expected, msg) {
  if (actual !== expected) {
    throw new Error((msg || 'assertEq') + ': expected ' +
      JSON.stringify(expected) + ', got ' + JSON.stringify(actual));
  }
}
function assertHas(obj, key, msg) {
  if (obj === null || obj === undefined || !(key in obj)) {
    throw new Error((msg || 'assertHas') + ': missing key "' + key +
      '" in ' + JSON.stringify(obj ? Object.keys(obj) : obj));
  }
}

let _passed = 0;
let _failed = 0;
const _failures = [];
function check(name, fn) {
  try {
    fn();
    _passed++;
    print('  PASS  ' + name);
  } catch (e) {
    _failed++;
    _failures.push({ name: name, err: e.message });
    print('  FAIL  ' + name + ': ' + e.message);
  }
}

print('=== ' + TEST_FILE + ' ===');

const testDb = db.getSiblingDB(DB_NAME);
testDb.dropDatabase();

check('ping returns ok=1', () => {
  const r = testDb.runCommand({ ping: 1 });
  assertEq(r.ok, 1, 'ping ok');
});

check('hello identifies a primary', () => {
  const r = testDb.runCommand({ hello: 1 });
  assertEq(r.ok, 1, 'hello ok');
  // Accept either the modern (isWritablePrimary) or legacy (ismaster) field.
  assert(r.isWritablePrimary === true || r.ismaster === true,
    'expected isWritablePrimary or ismaster to be true: ' + JSON.stringify(r));
  assertHas(r, 'maxBsonObjectSize');
  assert(typeof r.maxBsonObjectSize === 'number' && r.maxBsonObjectSize > 0,
    'maxBsonObjectSize should be a positive number');
});

check('isMaster legacy alias also responds', () => {
  const r = testDb.runCommand({ isMaster: 1 });
  assertEq(r.ok, 1, 'isMaster ok');
});

check('buildInfo returns a version string', () => {
  const r = testDb.runCommand({ buildInfo: 1 });
  assertEq(r.ok, 1, 'buildInfo ok');
  assertHas(r, 'version', 'buildInfo.version');
  assert(typeof r.version === 'string' && r.version.length > 0,
    'version not a non-empty string: ' + r.version);
});

check('connectionStatus returns authInfo', () => {
  const r = testDb.runCommand({ connectionStatus: 1 });
  assertEq(r.ok, 1, 'connectionStatus ok');
  assertHas(r, 'authInfo', 'authInfo');
});

check('listDatabases includes our test database after a write', () => {
  testDb.bootstrap_marker.insertOne({ _id: 1, marker: true });
  const r = db.getSiblingDB('admin').runCommand({ listDatabases: 1 });
  assertEq(r.ok, 1, 'listDatabases ok');
  assertHas(r, 'databases', 'databases array');
  const names = r.databases.map((x) => x.name);
  assert(names.includes(DB_NAME),
    'expected ' + DB_NAME + ' in listDatabases names: ' + JSON.stringify(names));
});

check('listCollections returns the created collection', () => {
  const cursor = testDb.runCommand({ listCollections: 1 });
  assertEq(cursor.ok, 1, 'listCollections ok');
  assertHas(cursor, 'cursor');
  const names = cursor.cursor.firstBatch.map((c) => c.name);
  assert(names.includes('bootstrap_marker'),
    'expected bootstrap_marker in listCollections: ' + JSON.stringify(names));
});

check('listCollections with name filter narrows results', () => {
  testDb.other_collection.insertOne({ _id: 1 });
  const cursor = testDb.runCommand({
    listCollections: 1,
    filter: { name: 'bootstrap_marker' },
  });
  assertEq(cursor.ok, 1, 'listCollections ok');
  const names = cursor.cursor.firstBatch.map((c) => c.name);
  assertEq(names.length, 1, 'filter should narrow to one collection');
  assertEq(names[0], 'bootstrap_marker');
});

check('dbStats reports our database name', () => {
  const r = testDb.runCommand({ dbStats: 1 });
  assertEq(r.ok, 1, 'dbStats ok');
  assertEq(r.db, DB_NAME, 'dbStats.db');
  assertHas(r, 'collections');
  assertHas(r, 'objects');
});

check('collStats reports namespace for a populated collection', () => {
  const r = testDb.runCommand({ collStats: 'bootstrap_marker' });
  assertEq(r.ok, 1, 'collStats ok');
  assertHas(r, 'ns', 'collStats.ns');
  assertEq(r.ns, DB_NAME + '.bootstrap_marker', 'collStats.ns value');
});

check('currentOp is reachable', () => {
  const r = db.getSiblingDB('admin').runCommand({ currentOp: 1 });
  assertEq(r.ok, 1, 'currentOp ok');
});

testDb.dropDatabase();

print('=== ' + TEST_FILE + ' summary: ' + _passed + ' passed, ' + _failed + ' failed ===');
if (_failed > 0) {
  for (const f of _failures) print('FAILURE: ' + f.name + ': ' + f.err);
  quit(1);
}
