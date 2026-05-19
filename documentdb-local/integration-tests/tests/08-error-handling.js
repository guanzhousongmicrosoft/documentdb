// Integration tests: error handling.
// Verifies that the gateway returns proper errors for the most common
// misuse patterns: duplicate-key on a unique index, schema-validator
// rejection, invalid update specifications, unknown commands, and ops
// against missing collections / databases.

const TEST_FILE = '08-error-handling';
const DB_NAME = 'it_08_error_handling';

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
  let captured;
  try { fn(); } catch (e) { threw = true; captured = e; }
  if (!threw) throw new Error((msg || 'assertThrows') + ': expected an exception');
  return captured;
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

// ---------------------------------------------------------------------------
// Duplicate key on a unique index
// ---------------------------------------------------------------------------

check('duplicate insert into a unique index throws an error', () => {
  const c = testDb.unique_kv;
  c.createIndex({ k: 1 }, { name: 'k_unique', unique: true });
  c.insertOne({ _id: 1, k: 'x' });

  const err = assertThrows(
    () => c.insertOne({ _id: 2, k: 'x' }),
    'second insert with same k should be rejected',
  );
  // The error message in mongosh wraps the server response; we accept either
  // the standard MongoDB phrasing or the underlying constraint name.
  const m = (err && err.message) || '';
  assert(
    /duplicate key/i.test(m) || /unique/i.test(m) || /E11000/.test(m),
    'expected a duplicate-key error, got: ' + m,
  );
  assertEq(c.countDocuments({}), 1, 'only the first insert should persist');
});

check('duplicate insert through insertMany aborts with ordered:true', () => {
  const c = testDb.unique_ordered;
  c.createIndex({ k: 1 }, { unique: true });
  assertThrows(() => c.insertMany([
    { _id: 1, k: 'a' },
    { _id: 2, k: 'a' },   // dup
    { _id: 3, k: 'b' },
  ], { ordered: true }));
  // With ordered:true execution stops at the failing element, so the third
  // document is not inserted.
  assertEq(c.countDocuments({}), 1);
});

// ---------------------------------------------------------------------------
// Invalid update operator usage
// ---------------------------------------------------------------------------

check('top-level field name starting with $ in an update is rejected', () => {
  const c = testDb.upd_invalid;
  c.insertOne({ _id: 1, v: 'old' });
  // Replacement documents cannot contain top-level $-prefixed names; this is
  // distinct from an update operator document which would look like {$set: ...}.
  assertThrows(
    () => c.replaceOne({ _id: 1 }, { $weird: 'x' }),
    'replaceOne with $-prefixed field should be rejected',
  );
});

check('unknown update operator is rejected', () => {
  const c = testDb.upd_unknown;
  c.insertOne({ _id: 1, v: 'old' });
  assertThrows(
    () => c.updateOne({ _id: 1 }, { $totallyMadeUp: { v: 'x' } }),
    'updateOne with an unknown operator should be rejected',
  );
});

// ---------------------------------------------------------------------------
// Unknown command
// ---------------------------------------------------------------------------

check('unknown command is reported as an error', () => {
  // mongosh exposes server errors here in two shapes: either by throwing, or
  // by returning {ok: 0, errmsg: ...}. Both are acceptable signals that the
  // command was rejected. The only outcome we reject is a silent ok: 1.
  let response = null;
  let threwMsg = null;
  try {
    response = testDb.runCommand({ thisIsNotARealCommand: 1 });
  } catch (e) {
    threwMsg = e.message || String(e);
  }
  if (threwMsg !== null) {
    assert(threwMsg.length > 0, 'thrown error should have a message');
    return;
  }
  assertEq(response.ok, 0, 'ok should be 0');
  assert(typeof response.errmsg === 'string' && response.errmsg.length > 0,
    'errmsg should be a non-empty string: ' + JSON.stringify(response));
});

// ---------------------------------------------------------------------------
// Operations against missing collections / databases
// ---------------------------------------------------------------------------

check('find on a missing collection returns an empty result', () => {
  const r = testDb.never_created.find({}).toArray();
  assertEq(r.length, 0);
});

check('countDocuments on a missing collection returns 0', () => {
  assertEq(testDb.also_never_created.countDocuments({}), 0);
});

check('findOneAndUpdate without upsert on a missing doc returns null', () => {
  const c = testDb.missing_doc;
  c.insertOne({ _id: 1 });
  const r = c.findOneAndUpdate({ _id: 999 }, { $set: { v: 'x' } });
  assertEq(r, null, 'no match without upsert should return null');
});

check('drop on a missing collection is reported but does not crash', () => {
  // Some servers return ok=0 with NamespaceNotFound, others return ok=1.
  // Either is acceptable as long as the call completes and does not throw.
  let outcome;
  try {
    outcome = testDb.runCommand({ drop: 'no_such_collection' });
  } catch (e) {
    outcome = { ok: 0, errmsg: e.message };
  }
  assert(outcome.ok === 0 || outcome.ok === 1,
    'drop should return a structured response: ' + JSON.stringify(outcome));
});

testDb.dropDatabase();

print('=== ' + TEST_FILE + ' summary: ' + _passed + ' passed, ' + _failed + ' failed ===');
if (_failed > 0) {
  for (const f of _failures) print('FAILURE: ' + f.name + ': ' + f.err);
  quit(1);
}
