// Integration tests: CRUD operations and query operators.
// Covers insertOne/insertMany, find/findOne with comparison/logical/element/
// regex/array operators, countDocuments/distinct, updateOne/updateMany/
// replaceOne, deleteOne/deleteMany, and the findOneAnd* family.

const TEST_FILE = '01-crud';
const DB_NAME = 'it_01_crud';

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
// insert
// ---------------------------------------------------------------------------

check('insertOne returns the inserted _id', () => {
  const c = testDb.t_insert;
  const r = c.insertOne({ _id: 1, name: 'alice', age: 30 });
  assertEq(r.acknowledged, true, 'acknowledged');
  assertEq(r.insertedId, 1, 'insertedId');
  assertEq(c.countDocuments({}), 1, 'count after insertOne');
});

check('insertMany returns one id per inserted doc', () => {
  const c = testDb.t_insert_many;
  const docs = [
    { _id: 1, v: 'a' },
    { _id: 2, v: 'b' },
    { _id: 3, v: 'c' },
  ];
  const r = c.insertMany(docs);
  assertEq(r.acknowledged, true);
  assertEq(Object.keys(r.insertedIds).length, 3, 'inserted ids length');
  assertEq(c.countDocuments({}), 3, 'count after insertMany');
});

check('insertOne with no _id generates an ObjectId', () => {
  const c = testDb.t_insert_oid;
  const r = c.insertOne({ name: 'noid' });
  assert(r.insertedId !== undefined && r.insertedId !== null,
    'insertedId should be present');
});

// ---------------------------------------------------------------------------
// find / findOne / count / distinct
// ---------------------------------------------------------------------------

const q = testDb.t_query;
q.insertMany([
  { _id: 1, name: 'alice', age: 30, city: 'Seattle', tags: ['a', 'b'], active: true },
  { _id: 2, name: 'bob', age: 25, city: 'Portland', tags: ['b', 'c'], active: false },
  { _id: 3, name: 'carol', age: 42, city: 'Seattle', tags: ['c', 'd'], active: true },
  { _id: 4, name: 'dave', age: 35, city: 'NYC', tags: ['d'], active: true, optional: 'x' },
  { _id: 5, name: 'eve', age: 28, city: 'NYC', tags: [], active: false },
]);

check('find returns all documents', () => {
  assertEq(q.find({}).toArray().length, 5);
});

check('findOne returns a single document', () => {
  const r = q.findOne({ _id: 1 });
  assertEq(r.name, 'alice');
});

check('findOne returns null when no match', () => {
  const r = q.findOne({ _id: 999 });
  assertEq(r, null);
});

check('countDocuments respects a filter', () => {
  assertEq(q.countDocuments({ city: 'Seattle' }), 2);
});

check('estimatedDocumentCount returns total count', () => {
  assertEq(q.estimatedDocumentCount(), 5);
});

check('distinct returns unique field values', () => {
  const cities = q.distinct('city').sort();
  assertDeepEq(cities, ['NYC', 'Portland', 'Seattle']);
});

// ---------------------------------------------------------------------------
// Comparison operators
// ---------------------------------------------------------------------------

check('$eq matches equal value', () => {
  assertEq(q.countDocuments({ age: { $eq: 30 } }), 1);
});

check('$ne matches unequal values', () => {
  assertEq(q.countDocuments({ age: { $ne: 30 } }), 4);
});

check('$gt matches greater than', () => {
  assertEq(q.countDocuments({ age: { $gt: 30 } }), 2);
});

check('$gte matches greater-than-or-equal', () => {
  assertEq(q.countDocuments({ age: { $gte: 30 } }), 3);
});

check('$lt matches less than', () => {
  assertEq(q.countDocuments({ age: { $lt: 30 } }), 2);
});

check('$lte matches less-than-or-equal', () => {
  assertEq(q.countDocuments({ age: { $lte: 30 } }), 3);
});

check('$in matches any of', () => {
  assertEq(q.countDocuments({ city: { $in: ['Seattle', 'NYC'] } }), 4);
});

check('$nin matches none of', () => {
  assertEq(q.countDocuments({ city: { $nin: ['Seattle', 'NYC'] } }), 1);
});

// ---------------------------------------------------------------------------
// Logical operators
// ---------------------------------------------------------------------------

check('$and combines clauses', () => {
  assertEq(q.countDocuments({ $and: [{ city: 'Seattle' }, { active: true }] }), 2);
});

check('$or combines clauses', () => {
  assertEq(q.countDocuments({ $or: [{ age: 25 }, { age: 42 }] }), 2);
});

check('$nor matches when no clause matches', () => {
  assertEq(q.countDocuments({ $nor: [{ city: 'Seattle' }, { city: 'NYC' }] }), 1);
});

check('$not negates a sub-expression', () => {
  assertEq(q.countDocuments({ age: { $not: { $gte: 30 } } }), 2);
});

// ---------------------------------------------------------------------------
// Element and evaluation operators
// ---------------------------------------------------------------------------

check('$exists true matches docs with field present', () => {
  assertEq(q.countDocuments({ optional: { $exists: true } }), 1);
});

check('$exists false matches docs without field', () => {
  assertEq(q.countDocuments({ optional: { $exists: false } }), 4);
});

check('$type matches by BSON type name', () => {
  assertEq(q.countDocuments({ active: { $type: 'bool' } }), 5);
});

check('$regex matches by pattern', () => {
  assertEq(q.countDocuments({ name: { $regex: '^a' } }), 1);
});

check('regex literal matches by pattern', () => {
  assertEq(q.countDocuments({ name: /o/ }), 2);
});

// ---------------------------------------------------------------------------
// Array operators
// ---------------------------------------------------------------------------

check('$all matches when all array values present', () => {
  assertEq(q.countDocuments({ tags: { $all: ['b', 'c'] } }), 1);
});

check('$size matches array length', () => {
  assertEq(q.countDocuments({ tags: { $size: 0 } }), 1);
});

check('$elemMatch matches element-by-element', () => {
  const c = testDb.t_elemmatch;
  c.insertMany([
    { _id: 1, scores: [{ s: 80 }, { s: 95 }] },
    { _id: 2, scores: [{ s: 60 }, { s: 70 }] },
  ]);
  assertEq(c.countDocuments({ scores: { $elemMatch: { s: { $gt: 90 } } } }), 1);
});

// ---------------------------------------------------------------------------
// Update operations
// ---------------------------------------------------------------------------

check('updateOne with $set modifies one document', () => {
  const c = testDb.t_update_one;
  c.insertOne({ _id: 1, v: 'a' });
  const r = c.updateOne({ _id: 1 }, { $set: { v: 'A' } });
  assertEq(r.matchedCount, 1);
  assertEq(r.modifiedCount, 1);
  assertEq(c.findOne({ _id: 1 }).v, 'A');
});

check('updateMany with $set modifies all matches', () => {
  const c = testDb.t_update_many;
  c.insertMany([{ _id: 1, g: 'a' }, { _id: 2, g: 'a' }, { _id: 3, g: 'b' }]);
  const r = c.updateMany({ g: 'a' }, { $set: { g: 'A' } });
  assertEq(r.matchedCount, 2);
  assertEq(r.modifiedCount, 2);
  assertEq(c.countDocuments({ g: 'A' }), 2);
});

check('replaceOne replaces the whole document (except _id)', () => {
  const c = testDb.t_replace;
  c.insertOne({ _id: 1, a: 1, b: 2 });
  const r = c.replaceOne({ _id: 1 }, { c: 3 });
  assertEq(r.matchedCount, 1);
  assertEq(r.modifiedCount, 1);
  const after = c.findOne({ _id: 1 });
  assertEq(after.c, 3);
  assert(!('a' in after) && !('b' in after),
    'old fields should be gone: ' + JSON.stringify(after));
});

check('upsert inserts when no match exists', () => {
  const c = testDb.t_upsert;
  const r = c.updateOne({ _id: 100 }, { $set: { v: 'new' } }, { upsert: true });
  assertEq(r.matchedCount, 0);
  assertEq(r.upsertedCount, 1);
  assertEq(c.findOne({ _id: 100 }).v, 'new');
});

// ---------------------------------------------------------------------------
// Delete operations
// ---------------------------------------------------------------------------

check('deleteOne removes one document', () => {
  const c = testDb.t_delete_one;
  c.insertMany([{ _id: 1 }, { _id: 2 }, { _id: 3 }]);
  const r = c.deleteOne({ _id: 2 });
  assertEq(r.deletedCount, 1);
  assertEq(c.countDocuments({}), 2);
});

check('deleteMany removes all matching documents', () => {
  const c = testDb.t_delete_many;
  c.insertMany([{ _id: 1, g: 'a' }, { _id: 2, g: 'a' }, { _id: 3, g: 'b' }]);
  const r = c.deleteMany({ g: 'a' });
  assertEq(r.deletedCount, 2);
  assertEq(c.countDocuments({}), 1);
});

// ---------------------------------------------------------------------------
// findOneAnd* family
// ---------------------------------------------------------------------------

check('findOneAndUpdate returns the document before update by default', () => {
  const c = testDb.t_foau;
  c.insertOne({ _id: 1, v: 'old' });
  const before = c.findOneAndUpdate({ _id: 1 }, { $set: { v: 'new' } });
  assertEq(before.v, 'old');
  assertEq(c.findOne({ _id: 1 }).v, 'new');
});

check('findOneAndUpdate with returnDocument:after returns the new doc', () => {
  const c = testDb.t_foau_after;
  c.insertOne({ _id: 1, v: 'old' });
  const after = c.findOneAndUpdate(
    { _id: 1 },
    { $set: { v: 'new' } },
    { returnDocument: 'after' },
  );
  assertEq(after.v, 'new');
});

check('findOneAndReplace replaces and returns the previous document', () => {
  const c = testDb.t_foar;
  c.insertOne({ _id: 1, a: 1 });
  const before = c.findOneAndReplace({ _id: 1 }, { b: 2 });
  assertEq(before.a, 1);
  const after = c.findOne({ _id: 1 });
  assertEq(after.b, 2);
  assert(!('a' in after), 'old fields should be removed');
});

check('findOneAndDelete removes and returns the deleted document', () => {
  const c = testDb.t_foad;
  c.insertOne({ _id: 1, v: 'x' });
  const removed = c.findOneAndDelete({ _id: 1 });
  assertEq(removed.v, 'x');
  assertEq(c.findOne({ _id: 1 }), null);
});

testDb.dropDatabase();

print('=== ' + TEST_FILE + ' summary: ' + _passed + ' passed, ' + _failed + ' failed ===');
if (_failed > 0) {
  for (const f of _failures) print('FAILURE: ' + f.name + ': ' + f.err);
  quit(1);
}
