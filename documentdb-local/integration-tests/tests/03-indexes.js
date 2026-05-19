// Integration tests: indexes.
// Covers createIndex variants (single field, compound, unique, sparse,
// partial, TTL, multikey), listIndexes, getIndexes, dropIndex by name and
// by spec, dropIndexes, and verifies unique-constraint enforcement.

const TEST_FILE = '03-indexes';
const DB_NAME = 'it_03_indexes';

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

function findIndex(c, name) {
  return c.getIndexes().find((i) => i.name === name);
}

print('=== ' + TEST_FILE + ' ===');

const testDb = db.getSiblingDB(DB_NAME);
testDb.dropDatabase();

// ---------------------------------------------------------------------------
// Default index
// ---------------------------------------------------------------------------

check('every collection starts with an _id index', () => {
  const c = testDb.t_default;
  c.insertOne({ _id: 1 });
  const idx = findIndex(c, '_id_');
  assert(idx !== undefined, '_id_ index should exist');
});

// ---------------------------------------------------------------------------
// Single-field and compound indexes
// ---------------------------------------------------------------------------

check('single-field index is created and listed', () => {
  const c = testDb.t_single;
  c.insertMany([{ a: 1 }, { a: 2 }, { a: 3 }]);
  c.createIndex({ a: 1 }, { name: 'a_1' });
  const idx = findIndex(c, 'a_1');
  assert(idx !== undefined, 'a_1 should be present');
});

check('compound index is created and listed', () => {
  const c = testDb.t_compound;
  c.insertMany([{ a: 1, b: 'x' }, { a: 2, b: 'y' }]);
  c.createIndex({ a: 1, b: -1 }, { name: 'a_1_b_-1' });
  const idx = findIndex(c, 'a_1_b_-1');
  assert(idx !== undefined, 'compound index should be present');
});

check('listIndexes command returns at least the _id index', () => {
  const c = testDb.t_single;
  const r = testDb.runCommand({ listIndexes: 't_single' });
  assertEq(r.ok, 1, 'listIndexes ok');
  const names = r.cursor.firstBatch.map((i) => i.name);
  assert(names.includes('_id_'), '_id_ should be returned');
});

// ---------------------------------------------------------------------------
// Unique indexes
// ---------------------------------------------------------------------------

check('unique index permits a single document per value', () => {
  const c = testDb.t_unique;
  c.createIndex({ email: 1 }, { name: 'email_unique', unique: true });
  c.insertOne({ _id: 1, email: 'a@example.com' });
  c.insertOne({ _id: 2, email: 'b@example.com' });
  assertEq(c.countDocuments({}), 2);
});

check('unique index rejects a duplicate value', () => {
  const c = testDb.t_unique;
  assertThrows(
    () => c.insertOne({ _id: 3, email: 'a@example.com' }),
    'duplicate insert should throw',
  );
});

// ---------------------------------------------------------------------------
// Sparse and partial indexes
// ---------------------------------------------------------------------------

check('sparse index excludes documents missing the field', () => {
  const c = testDb.t_sparse;
  c.insertMany([
    { _id: 1, opt: 'present' },
    { _id: 2 },
  ]);
  c.createIndex({ opt: 1 }, { name: 'opt_sparse', sparse: true });
  const idx = findIndex(c, 'opt_sparse');
  assert(idx !== undefined && idx.sparse === true,
    'sparse flag should be set: ' + JSON.stringify(idx));
});

check('partial index records partialFilterExpression', () => {
  const c = testDb.t_partial;
  c.insertMany([
    { _id: 1, status: 'active', s: 'a' },
    { _id: 2, status: 'inactive', s: 'b' },
  ]);
  c.createIndex(
    { s: 1 },
    { name: 's_partial', partialFilterExpression: { status: 'active' } },
  );
  const idx = findIndex(c, 's_partial');
  assert(idx !== undefined && idx.partialFilterExpression !== undefined,
    'partialFilterExpression should be recorded: ' + JSON.stringify(idx));
});

// ---------------------------------------------------------------------------
// TTL index
// ---------------------------------------------------------------------------

check('TTL index records expireAfterSeconds', () => {
  const c = testDb.t_ttl;
  c.createIndex(
    { createdAt: 1 },
    { name: 'createdAt_ttl', expireAfterSeconds: 60 },
  );
  const idx = findIndex(c, 'createdAt_ttl');
  assert(idx !== undefined, 'TTL index should be present');
  assertEq(idx.expireAfterSeconds, 60, 'expireAfterSeconds');
});

// ---------------------------------------------------------------------------
// Multikey (array field) index
// ---------------------------------------------------------------------------

check('multikey index supports array-element queries', () => {
  const c = testDb.t_multikey;
  c.insertMany([
    { _id: 1, tags: ['a', 'b'] },
    { _id: 2, tags: ['b', 'c'] },
    { _id: 3, tags: ['d'] },
  ]);
  c.createIndex({ tags: 1 }, { name: 'tags_1' });
  assertEq(c.countDocuments({ tags: 'b' }), 2);
});

// ---------------------------------------------------------------------------
// dropIndex variants
// ---------------------------------------------------------------------------

check('dropIndex by name removes the index', () => {
  const c = testDb.t_drop_by_name;
  c.createIndex({ a: 1 }, { name: 'a_idx' });
  c.dropIndex('a_idx');
  assert(findIndex(c, 'a_idx') === undefined,
    'a_idx should be removed: ' + JSON.stringify(c.getIndexes()));
});

check('dropIndex by key spec removes the index', () => {
  const c = testDb.t_drop_by_spec;
  c.createIndex({ b: 1 });
  c.dropIndex({ b: 1 });
  const names = c.getIndexes().map((i) => i.name);
  assert(!names.some((n) => n.startsWith('b_')),
    'b index should be removed: ' + JSON.stringify(names));
});

check('dropIndexes wildcard removes everything except _id', () => {
  const c = testDb.t_drop_all;
  c.createIndex({ a: 1 });
  c.createIndex({ b: 1 });
  c.dropIndexes('*');
  const names = c.getIndexes().map((i) => i.name);
  assertEq(names.length, 1, 'only _id should remain');
  assertEq(names[0], '_id_');
});

testDb.dropDatabase();

print('=== ' + TEST_FILE + ' summary: ' + _passed + ' passed, ' + _failed + ' failed ===');
if (_failed > 0) {
  for (const f of _failures) print('FAILURE: ' + f.name + ': ' + f.err);
  quit(1);
}
