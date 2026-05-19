// Integration tests: update operators.
// Covers the field update operators ($set, $unset, $inc, $mul, $min, $max,
// $rename, $currentDate, $setOnInsert) and the array update operators
// ($push, $pop, $pull, $pullAll, $addToSet) including their modifiers
// ($each, $sort, $slice, $position), plus the positional update operators.

const TEST_FILE = '02-update-operators';
const DB_NAME = 'it_02_update_operators';

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
// Field operators
// ---------------------------------------------------------------------------

check('$set creates a missing field', () => {
  const c = testDb.t_set_new;
  c.insertOne({ _id: 1 });
  c.updateOne({ _id: 1 }, { $set: { added: 'x' } });
  assertEq(c.findOne({ _id: 1 }).added, 'x');
});

check('$set overwrites an existing field', () => {
  const c = testDb.t_set_over;
  c.insertOne({ _id: 1, v: 'old' });
  c.updateOne({ _id: 1 }, { $set: { v: 'new' } });
  assertEq(c.findOne({ _id: 1 }).v, 'new');
});

check('$unset removes a field', () => {
  const c = testDb.t_unset;
  c.insertOne({ _id: 1, keep: 1, drop: 2 });
  c.updateOne({ _id: 1 }, { $unset: { drop: '' } });
  const doc = c.findOne({ _id: 1 });
  assert('keep' in doc, 'keep should remain');
  assert(!('drop' in doc), 'drop should be removed');
});

check('$inc increments a numeric field', () => {
  const c = testDb.t_inc;
  c.insertOne({ _id: 1, n: 10 });
  c.updateOne({ _id: 1 }, { $inc: { n: 5 } });
  assertEq(c.findOne({ _id: 1 }).n, 15);
});

check('$inc on missing field creates it', () => {
  const c = testDb.t_inc_new;
  c.insertOne({ _id: 1 });
  c.updateOne({ _id: 1 }, { $inc: { n: 3 } });
  assertEq(c.findOne({ _id: 1 }).n, 3);
});

check('$mul multiplies a numeric field', () => {
  const c = testDb.t_mul;
  c.insertOne({ _id: 1, n: 4 });
  c.updateOne({ _id: 1 }, { $mul: { n: 3 } });
  assertEq(c.findOne({ _id: 1 }).n, 12);
});

check('$min keeps the smaller value', () => {
  const c = testDb.t_min;
  c.insertOne({ _id: 1, n: 10 });
  c.updateOne({ _id: 1 }, { $min: { n: 5 } });
  assertEq(c.findOne({ _id: 1 }).n, 5);
  c.updateOne({ _id: 1 }, { $min: { n: 50 } });
  assertEq(c.findOne({ _id: 1 }).n, 5, '$min should not overwrite smaller value');
});

check('$max keeps the larger value', () => {
  const c = testDb.t_max;
  c.insertOne({ _id: 1, n: 5 });
  c.updateOne({ _id: 1 }, { $max: { n: 10 } });
  assertEq(c.findOne({ _id: 1 }).n, 10);
  c.updateOne({ _id: 1 }, { $max: { n: 1 } });
  assertEq(c.findOne({ _id: 1 }).n, 10, '$max should not overwrite larger value');
});

check('$rename changes a field name', () => {
  const c = testDb.t_rename;
  c.insertOne({ _id: 1, oldName: 'value' });
  c.updateOne({ _id: 1 }, { $rename: { oldName: 'newName' } });
  const doc = c.findOne({ _id: 1 });
  assert(!('oldName' in doc), 'oldName should be gone');
  assertEq(doc.newName, 'value');
});

check('$currentDate sets a Date value', () => {
  const c = testDb.t_currentdate;
  c.insertOne({ _id: 1 });
  c.updateOne({ _id: 1 }, { $currentDate: { ts: true } });
  const doc = c.findOne({ _id: 1 });
  assert(doc.ts instanceof Date,
    '$currentDate should yield a Date, got: ' + typeof doc.ts);
});

check('$setOnInsert applies only on upsert insert', () => {
  const c = testDb.t_setoninsert;
  // Upsert path: no match exists, so $setOnInsert should apply.
  c.updateOne(
    { _id: 1 },
    { $set: { changeable: 'first' }, $setOnInsert: { createdBy: 'init' } },
    { upsert: true },
  );
  let doc = c.findOne({ _id: 1 });
  assertEq(doc.createdBy, 'init', 'createdBy from $setOnInsert');
  assertEq(doc.changeable, 'first');

  // Match path: $setOnInsert should NOT modify createdBy.
  c.updateOne(
    { _id: 1 },
    { $set: { changeable: 'second' }, $setOnInsert: { createdBy: 'CHANGED' } },
    { upsert: true },
  );
  doc = c.findOne({ _id: 1 });
  assertEq(doc.createdBy, 'init', '$setOnInsert must not run on match');
  assertEq(doc.changeable, 'second');
});

// ---------------------------------------------------------------------------
// Array operators
// ---------------------------------------------------------------------------

check('$push appends one element', () => {
  const c = testDb.t_push;
  c.insertOne({ _id: 1, items: ['a'] });
  c.updateOne({ _id: 1 }, { $push: { items: 'b' } });
  assertDeepEq(c.findOne({ _id: 1 }).items, ['a', 'b']);
});

check('$push with $each appends multiple elements', () => {
  const c = testDb.t_push_each;
  c.insertOne({ _id: 1, items: ['a'] });
  c.updateOne({ _id: 1 }, { $push: { items: { $each: ['b', 'c'] } } });
  assertDeepEq(c.findOne({ _id: 1 }).items, ['a', 'b', 'c']);
});

check('$push with $each + $sort sorts after appending', () => {
  const c = testDb.t_push_sort;
  c.insertOne({ _id: 1, nums: [3, 1] });
  c.updateOne(
    { _id: 1 },
    { $push: { nums: { $each: [4, 2], $sort: 1 } } },
  );
  assertDeepEq(c.findOne({ _id: 1 }).nums, [1, 2, 3, 4]);
});

check('$push with $each + $slice truncates', () => {
  const c = testDb.t_push_slice;
  c.insertOne({ _id: 1, items: ['a', 'b'] });
  c.updateOne(
    { _id: 1 },
    { $push: { items: { $each: ['c', 'd', 'e'], $slice: -3 } } },
  );
  assertDeepEq(c.findOne({ _id: 1 }).items, ['c', 'd', 'e']);
});

check('$pop -1 removes the first element', () => {
  const c = testDb.t_pop_first;
  c.insertOne({ _id: 1, items: ['a', 'b', 'c'] });
  c.updateOne({ _id: 1 }, { $pop: { items: -1 } });
  assertDeepEq(c.findOne({ _id: 1 }).items, ['b', 'c']);
});

check('$pop 1 removes the last element', () => {
  const c = testDb.t_pop_last;
  c.insertOne({ _id: 1, items: ['a', 'b', 'c'] });
  c.updateOne({ _id: 1 }, { $pop: { items: 1 } });
  assertDeepEq(c.findOne({ _id: 1 }).items, ['a', 'b']);
});

check('$pull removes matching elements', () => {
  const c = testDb.t_pull;
  c.insertOne({ _id: 1, items: ['a', 'b', 'a', 'c'] });
  c.updateOne({ _id: 1 }, { $pull: { items: 'a' } });
  assertDeepEq(c.findOne({ _id: 1 }).items, ['b', 'c']);
});

check('$pullAll removes any of multiple values', () => {
  const c = testDb.t_pullall;
  c.insertOne({ _id: 1, items: ['a', 'b', 'c', 'd'] });
  c.updateOne({ _id: 1 }, { $pullAll: { items: ['b', 'd'] } });
  assertDeepEq(c.findOne({ _id: 1 }).items, ['a', 'c']);
});

check('$addToSet adds only when not present', () => {
  const c = testDb.t_addtoset;
  c.insertOne({ _id: 1, items: ['a', 'b'] });
  c.updateOne({ _id: 1 }, { $addToSet: { items: 'a' } });
  assertDeepEq(c.findOne({ _id: 1 }).items, ['a', 'b'], 'duplicate not added');
  c.updateOne({ _id: 1 }, { $addToSet: { items: 'c' } });
  assertDeepEq(c.findOne({ _id: 1 }).items, ['a', 'b', 'c']);
});

check('$addToSet with $each adds multiple distinct values', () => {
  const c = testDb.t_addtoset_each;
  c.insertOne({ _id: 1, items: ['a'] });
  c.updateOne({ _id: 1 }, { $addToSet: { items: { $each: ['a', 'b', 'c'] } } });
  assertDeepEq(c.findOne({ _id: 1 }).items.sort(), ['a', 'b', 'c']);
});

// ---------------------------------------------------------------------------
// Positional operators
// ---------------------------------------------------------------------------

check('$ positional updates the matched array element', () => {
  const c = testDb.t_positional;
  c.insertOne({ _id: 1, scores: [{ id: 'a', n: 10 }, { id: 'b', n: 20 }] });
  c.updateOne(
    { _id: 1, 'scores.id': 'b' },
    { $set: { 'scores.$.n': 99 } },
  );
  const doc = c.findOne({ _id: 1 });
  assertEq(doc.scores[0].n, 10);
  assertEq(doc.scores[1].n, 99);
});

check('$[] applies to all array elements', () => {
  const c = testDb.t_all_positional;
  c.insertOne({ _id: 1, nums: [1, 2, 3] });
  c.updateOne({ _id: 1 }, { $inc: { 'nums.$[]': 10 } });
  assertDeepEq(c.findOne({ _id: 1 }).nums, [11, 12, 13]);
});

testDb.dropDatabase();

print('=== ' + TEST_FILE + ' summary: ' + _passed + ' passed, ' + _failed + ' failed ===');
if (_failed > 0) {
  for (const f of _failures) print('FAILURE: ' + f.name + ': ' + f.err);
  quit(1);
}
