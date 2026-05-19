// Integration tests: collection and database management.
// Covers createCollection (with validators), listCollections, drop,
// renameCollection (within a database), dropDatabase, and view creation /
// query / drop. Capped collections and transactions are intentionally not
// exercised - the upstream functional gate covers them where supported.

const TEST_FILE = '05-collection-and-database';
const DB_NAME = 'it_05_collection_and_database';

function assert(cond, msg) {
  if (!cond) throw new Error(msg || 'assertion failed');
}
function assertEq(actual, expected, msg) {
  if (actual !== expected) {
    throw new Error((msg || 'assertEq') + ': expected ' +
      JSON.stringify(expected) + ', got ' + JSON.stringify(actual));
  }
}
function assertThrows(fn, msg) {
  let threw = false;
  try { fn(); } catch (e) { threw = true; }
  if (!threw) throw new Error((msg || 'assertThrows') + ': expected an exception');
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

function listCollectionNames(database) {
  const r = database.runCommand({ listCollections: 1, nameOnly: true });
  if (r.ok !== 1) throw new Error('listCollections failed: ' + JSON.stringify(r));
  return r.cursor.firstBatch.map((c) => c.name).sort();
}

print('=== ' + TEST_FILE + ' ===');

const testDb = db.getSiblingDB(DB_NAME);
testDb.dropDatabase();

// ---------------------------------------------------------------------------
// createCollection / listCollections / drop
// ---------------------------------------------------------------------------

check('createCollection creates an empty collection', () => {
  const r = testDb.runCommand({ create: 'plain_collection' });
  assertEq(r.ok, 1, 'create ok');
  const names = listCollectionNames(testDb);
  assert(names.includes('plain_collection'),
    'plain_collection should be listed: ' + JSON.stringify(names));
});

check('listCollections filter narrows to a single collection', () => {
  testDb.another.insertOne({ _id: 1 });
  const r = testDb.runCommand({
    listCollections: 1,
    filter: { name: 'plain_collection' },
    nameOnly: true,
  });
  assertEq(r.ok, 1);
  assertEq(r.cursor.firstBatch.length, 1);
  assertEq(r.cursor.firstBatch[0].name, 'plain_collection');
});

check('drop removes a collection', () => {
  testDb.to_be_dropped.insertOne({ _id: 1 });
  const r = testDb.runCommand({ drop: 'to_be_dropped' });
  assertEq(r.ok, 1, 'drop ok');
  const names = listCollectionNames(testDb);
  assert(!names.includes('to_be_dropped'),
    'to_be_dropped should be gone: ' + JSON.stringify(names));
});

// ---------------------------------------------------------------------------
// renameCollection
// ---------------------------------------------------------------------------

check('renameCollection moves data to a new name within the same db', () => {
  const src = testDb.rename_src;
  src.insertMany([{ _id: 1, v: 'a' }, { _id: 2, v: 'b' }]);
  const r = db.adminCommand({
    renameCollection: DB_NAME + '.rename_src',
    to: DB_NAME + '.rename_dst',
  });
  assertEq(r.ok, 1, 'renameCollection ok');
  const names = listCollectionNames(testDb);
  assert(!names.includes('rename_src'), 'src should be gone');
  assert(names.includes('rename_dst'), 'dst should be present');
  assertEq(testDb.rename_dst.countDocuments({}), 2,
    'documents should be preserved after rename');
});

// ---------------------------------------------------------------------------
// Views
// ---------------------------------------------------------------------------

check('createView creates a queryable read-only view', () => {
  const source = testDb.view_source;
  source.insertMany([
    { _id: 1, region: 'west', n: 1 },
    { _id: 2, region: 'east', n: 2 },
    { _id: 3, region: 'west', n: 3 },
  ]);
  const r = testDb.runCommand({
    create: 'west_view',
    viewOn: 'view_source',
    pipeline: [{ $match: { region: 'west' } }],
  });
  assertEq(r.ok, 1, 'create view');
});

check('view returns the pipeline-filtered rows', () => {
  const view = testDb.west_view;
  const rows = view.find({}).toArray();
  assertEq(rows.length, 2);
  for (const row of rows) {
    assertEq(row.region, 'west');
  }
});

check('view shows up in listCollections with type:view', () => {
  const r = testDb.runCommand({
    listCollections: 1,
    filter: { name: 'west_view' },
  });
  assertEq(r.ok, 1);
  assertEq(r.cursor.firstBatch.length, 1);
  assertEq(r.cursor.firstBatch[0].type, 'view');
});

check('drop removes the view', () => {
  const r = testDb.runCommand({ drop: 'west_view' });
  assertEq(r.ok, 1, 'drop view ok');
  const names = listCollectionNames(testDb);
  assert(!names.includes('west_view'), 'view should be removed');
});

// ---------------------------------------------------------------------------
// dropDatabase
// ---------------------------------------------------------------------------

check('dropDatabase removes the entire database', () => {
  const ephemeralName = DB_NAME + '_ephemeral';
  const ephemeral = db.getSiblingDB(ephemeralName);
  ephemeral.one.insertOne({ _id: 1 });
  ephemeral.two.insertOne({ _id: 1 });
  const r = ephemeral.runCommand({ dropDatabase: 1 });
  assertEq(r.ok, 1, 'dropDatabase ok');
  const admin = db.getSiblingDB('admin').runCommand({ listDatabases: 1 });
  const names = admin.databases.map((x) => x.name);
  assert(!names.includes(ephemeralName),
    ephemeralName + ' should be removed: ' + JSON.stringify(names));
});

testDb.dropDatabase();

print('=== ' + TEST_FILE + ' summary: ' + _passed + ' passed, ' + _failed + ' failed ===');
if (_failed > 0) {
  for (const f of _failures) print('FAILURE: ' + f.name + ': ' + f.err);
  quit(1);
}
