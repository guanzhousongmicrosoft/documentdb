// Integration tests: cursors and projection.
// Covers projection forms (inclusion, exclusion, $slice, $elemMatch),
// the find->getMore loop driven by batchSize, cursor iteration with
// hasNext/next, sort+skip+limit ordering, and explicit cursor close.

const TEST_FILE = '07-cursors-and-projection';
const DB_NAME = 'it_07_cursors_and_projection';

function assert(cond, msg) {
  if (!cond) throw new Error(msg || 'assertion failed');
}
function assertEq(actual, expected, msg) {
  if (actual !== expected) {
    throw new Error((msg || 'assertEq') + ': expected ' +
      JSON.stringify(expected) + ', got ' + JSON.stringify(actual));
  }
}
function assertDeepEq(actual, expected, msg) {
  const a = JSON.stringify(actual);
  const e = JSON.stringify(expected);
  if (a !== e) {
    throw new Error((msg || 'assertDeepEq') + ': expected ' + e + ', got ' + a);
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

// ---------------------------------------------------------------------------
// Projection: inclusion, exclusion, computed
// ---------------------------------------------------------------------------

const proj = testDb.proj;
proj.insertMany([
  { _id: 1, name: 'alice', age: 30, city: 'Seattle', tags: ['a', 'b', 'c'] },
  { _id: 2, name: 'bob',   age: 25, city: 'Portland', tags: ['c', 'd'] },
]);

check('projection inclusion returns only specified fields (+ _id)', () => {
  const doc = proj.findOne({ _id: 1 }, { name: 1 });
  assertDeepEq(Object.keys(doc).sort(), ['_id', 'name']);
  assertEq(doc.name, 'alice');
});

check('projection inclusion can suppress _id with _id:0', () => {
  const doc = proj.findOne({ _id: 1 }, { _id: 0, name: 1 });
  assertDeepEq(Object.keys(doc).sort(), ['name']);
});

check('projection exclusion drops only specified fields', () => {
  const doc = proj.findOne({ _id: 1 }, { city: 0, tags: 0 });
  assertDeepEq(Object.keys(doc).sort(), ['_id', 'age', 'name']);
});

// ---------------------------------------------------------------------------
// Array projection operators
// ---------------------------------------------------------------------------

check('$slice in projection takes the first N elements', () => {
  const doc = proj.findOne({ _id: 1 }, { tags: { $slice: 2 }, _id: 0, name: 1 });
  assertDeepEq(doc.tags, ['a', 'b']);
});

check('$slice with negative N takes the last elements', () => {
  const doc = proj.findOne({ _id: 1 }, { tags: { $slice: -1 }, _id: 0 });
  assertDeepEq(doc.tags, ['c']);
});

check('$slice with [skip, limit] takes a window', () => {
  const doc = proj.findOne({ _id: 1 }, { tags: { $slice: [1, 1] }, _id: 0 });
  assertDeepEq(doc.tags, ['b']);
});

check('$elemMatch projection returns the first matching array element', () => {
  const c = testDb.elem_proj;
  c.insertOne({
    _id: 1,
    scores: [{ s: 70, t: 'a' }, { s: 95, t: 'b' }, { s: 85, t: 'c' }],
  });
  const doc = c.findOne(
    { _id: 1 },
    { scores: { $elemMatch: { s: { $gt: 90 } } }, _id: 0 },
  );
  assertEq(doc.scores.length, 1);
  assertEq(doc.scores[0].t, 'b');
});

// ---------------------------------------------------------------------------
// sort + skip + limit interaction
// ---------------------------------------------------------------------------

check('sort + skip + limit returns the expected window', () => {
  const c = testDb.window;
  c.insertMany([
    { _id: 1, n: 30 },
    { _id: 2, n: 10 },
    { _id: 3, n: 20 },
    { _id: 4, n: 50 },
    { _id: 5, n: 40 },
  ]);
  const r = c.find({}, { _id: 0, n: 1 })
    .sort({ n: 1 }).skip(1).limit(2).toArray();
  assertDeepEq(r.map((x) => x.n), [20, 30]);
});

check('descending sort works', () => {
  const c = testDb.window;
  const r = c.find({}, { _id: 0, n: 1 })
    .sort({ n: -1 }).limit(2).toArray();
  assertDeepEq(r.map((x) => x.n), [50, 40]);
});

// ---------------------------------------------------------------------------
// Cursor iteration: hasNext / next, batchSize-driven getMore
// ---------------------------------------------------------------------------

check('hasNext / next iterate every document', () => {
  const c = testDb.iter;
  for (let i = 1; i <= 25; i++) c.insertOne({ _id: i });
  const cursor = c.find({}).sort({ _id: 1 });
  const ids = [];
  while (cursor.hasNext()) ids.push(cursor.next()._id);
  assertEq(ids.length, 25);
  assertEq(ids[0], 1);
  assertEq(ids[24], 25);
});

check('batchSize forces getMore to fetch all 100 docs', () => {
  const c = testDb.batched;
  const docs = [];
  for (let i = 1; i <= 100; i++) docs.push({ _id: i, n: i });
  c.insertMany(docs);

  const cursor = c.find({}).batchSize(7).sort({ _id: 1 });
  let count = 0;
  while (cursor.hasNext()) {
    cursor.next();
    count++;
  }
  assertEq(count, 100,
    'all docs must be fetched across multiple batches');
});

check('toArray returns the full result set', () => {
  const c = testDb.batched;
  const all = c.find({}).toArray();
  assertEq(all.length, 100);
});

check('forEach visits every document exactly once', () => {
  const c = testDb.batched;
  let total = 0;
  c.find({}, { _id: 0, n: 1 }).forEach((d) => { total += d.n; });
  // Sum 1..100 = 5050
  assertEq(total, 5050);
});

// ---------------------------------------------------------------------------
// Cursor close
// ---------------------------------------------------------------------------

check('cursor.close() succeeds even before iteration is complete', () => {
  const c = testDb.batched;
  const cursor = c.find({}).batchSize(5);
  cursor.next();
  cursor.close();
  // After close, additional next() calls should not blow up the test
  // process; we just assert close() did not throw.
  assert(true, 'cursor.close did not throw');
});

testDb.dropDatabase();

print('=== ' + TEST_FILE + ' summary: ' + _passed + ' passed, ' + _failed + ' failed ===');
if (_failed > 0) {
  for (const f of _failures) print('FAILURE: ' + f.name + ': ' + f.err);
  quit(1);
}
