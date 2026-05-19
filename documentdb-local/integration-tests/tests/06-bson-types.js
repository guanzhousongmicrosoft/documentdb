// Integration tests: BSON types.
// Inserts and reads back representative values for every BSON type the
// gateway exposes through mongosh, and verifies that the matching $type
// query operator selects them. Types covered: ObjectId, String, Int32
// (NumberInt), Int64 (NumberLong), Double, Decimal128 (NumberDecimal),
// Boolean, Null, Array, EmbeddedDocument, Date, Timestamp, BinData,
// Regex, MinKey, MaxKey.

const TEST_FILE = '06-bson-types';
const DB_NAME = 'it_06_bson_types';

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

const c = testDb.bson;
const oid = new ObjectId();
const fixedDate = new Date('2024-06-15T12:34:56.789Z');
const ts = new Timestamp(1700000000, 1);
const bin = new BinData(0, 'aGVsbG8=');                       // "hello"
const regex = /^abc/i;
const decimal = NumberDecimal('1234.5678');
const int32 = NumberInt(42);
const int64 = NumberLong('9007199254740993');                 // > 2^53

c.insertMany([
  { _id: 'oid',     v: oid,           probe: 'objectId' },
  { _id: 'str',     v: 'hello',       probe: 'string' },
  { _id: 'int32',   v: int32,         probe: 'int' },
  { _id: 'int64',   v: int64,         probe: 'long' },
  { _id: 'double',  v: 3.14159,       probe: 'double' },
  { _id: 'decimal', v: decimal,       probe: 'decimal' },
  { _id: 'bool',    v: true,          probe: 'bool' },
  { _id: 'null',    v: null,          probe: 'null' },
  { _id: 'array',   v: [1, 2, 3],     probe: 'array' },
  { _id: 'object',  v: { a: 1, b: 2 }, probe: 'object' },
  { _id: 'date',    v: fixedDate,     probe: 'date' },
  { _id: 'ts',      v: ts,            probe: 'timestamp' },
  { _id: 'bin',     v: bin,           probe: 'binData' },
  { _id: 'regex',   v: regex,         probe: 'regex' },
  { _id: 'minkey',  v: MinKey(),      probe: 'minKey' },
  { _id: 'maxkey',  v: MaxKey(),      probe: 'maxKey' },
]);

// ---------------------------------------------------------------------------
// Round-trip checks
// ---------------------------------------------------------------------------

check('ObjectId round-trips', () => {
  const doc = c.findOne({ _id: 'oid' });
  assert(doc.v instanceof ObjectId, 'v should be an ObjectId');
  assertEq(doc.v.toHexString(), oid.toHexString());
});

check('String round-trips', () => {
  assertEq(c.findOne({ _id: 'str' }).v, 'hello');
});

check('Int32 (NumberInt) round-trips and matches numerically', () => {
  const doc = c.findOne({ _id: 'int32' });
  assertEq(doc.v, 42);
});

check('Int64 (NumberLong) preserves precision beyond 2^53', () => {
  const doc = c.findOne({ _id: 'int64' });
  // NumberLong values stringify to their integer representation.
  assertEq(String(doc.v), '9007199254740993');
});

check('Double round-trips', () => {
  assertEq(c.findOne({ _id: 'double' }).v, 3.14159);
});

check('Decimal128 (NumberDecimal) round-trips', () => {
  const doc = c.findOne({ _id: 'decimal' });
  assertEq(doc.v.toString(), '1234.5678');
});

check('Boolean round-trips', () => {
  assertEq(c.findOne({ _id: 'bool' }).v, true);
});

check('Null round-trips and matches with {field: null}', () => {
  const doc = c.findOne({ _id: 'null' });
  assertEq(doc.v, null);
});

check('Array round-trips', () => {
  assertDeepEq(c.findOne({ _id: 'array' }).v, [1, 2, 3]);
});

check('EmbeddedDocument round-trips', () => {
  assertDeepEq(c.findOne({ _id: 'object' }).v, { a: 1, b: 2 });
});

check('Date round-trips to the same instant', () => {
  const doc = c.findOne({ _id: 'date' });
  assert(doc.v instanceof Date, 'v should be a Date');
  assertEq(doc.v.toISOString(), fixedDate.toISOString());
});

check('Timestamp round-trips with t and i', () => {
  const doc = c.findOne({ _id: 'ts' });
  assertEq(doc.v.t, 1700000000);
  assertEq(doc.v.i, 1);
});

check('BinData round-trips with subtype 0', () => {
  const doc = c.findOne({ _id: 'bin' });
  // mongosh 8 / BSON 6 surfaces BinData as a Binary object: subtype is the
  // .sub_type property (not a callable .subtype() method) and the value is
  // not necessarily an `instanceof BinData` literal. We accept either shape
  // by reading whichever accessor is present.
  let subtype;
  if (doc.v && typeof doc.v.sub_type === 'number') {
    subtype = doc.v.sub_type;
  } else if (doc.v && typeof doc.v.subtype === 'function') {
    subtype = doc.v.subtype();
  } else {
    throw new Error('v is not a BinData/Binary: ' + JSON.stringify(doc.v));
  }
  assertEq(subtype, 0, 'subtype 0');
});

check('Regex literal round-trips with source and flags', () => {
  const doc = c.findOne({ _id: 'regex' });
  // DocumentDB returns a BSON regex which mongosh may surface either as a
  // native JS RegExp or as a BSONRegExp wrapper with .pattern/.options.
  let pattern;
  let flags;
  if (doc.v instanceof RegExp) {
    pattern = doc.v.source;
    flags = doc.v.flags;
  } else if (doc.v && typeof doc.v.pattern === 'string') {
    pattern = doc.v.pattern;
    flags = typeof doc.v.options === 'string' ? doc.v.options : '';
  } else {
    throw new Error('v is not a Regex/BSONRegExp: ' + JSON.stringify(doc.v));
  }
  assertEq(pattern, '^abc', 'pattern');
  assert(flags.includes('i'), 'i flag should be preserved (flags=' + flags + ')');
});

check('MinKey and MaxKey round-trip and sort to the extremes', () => {
  // Use a sort to verify that MinKey sorts before everything and MaxKey
  // after everything.
  const cAll = testDb.minmax_sort;
  cAll.insertMany([
    { _id: 'a', v: MaxKey() },
    { _id: 'b', v: 'middle' },
    { _id: 'c', v: MinKey() },
  ]);
  const sorted = cAll.find({}).sort({ v: 1 }).toArray();
  assertEq(sorted[0]._id, 'c', 'MinKey sorts first');
  assertEq(sorted[2]._id, 'a', 'MaxKey sorts last');
});

// ---------------------------------------------------------------------------
// $type queries (use BSON type-alias strings)
// ---------------------------------------------------------------------------

const typeProbes = [
  ['objectId', 'oid'],
  ['string',   'str'],
  ['int',      'int32'],
  ['long',     'int64'],
  ['double',   'double'],
  ['decimal',  'decimal'],
  ['bool',     'bool'],
  ['null',     'null'],
  ['array',    'array'],
  ['object',   'object'],
  ['date',     'date'],
  ['timestamp','ts'],
  ['binData',  'bin'],
  ['regex',    'regex'],
  ['minKey',   'minkey'],
  ['maxKey',   'maxkey'],
];

for (const [typeName, expectedId] of typeProbes) {
  check('$type "' + typeName + '" selects the ' + expectedId + ' doc', () => {
    const found = c.find({ v: { $type: typeName } }, { _id: 1 }).toArray()
      .map((d) => d._id);
    assert(found.includes(expectedId),
      typeName + ' query should include ' + expectedId + ', got: ' +
        JSON.stringify(found));
  });
}

testDb.dropDatabase();

print('=== ' + TEST_FILE + ' summary: ' + _passed + ' passed, ' + _failed + ' failed ===');
if (_failed > 0) {
  for (const f of _failures) print('FAILURE: ' + f.name + ': ' + f.err);
  quit(1);
}
