// Integration tests: aggregation pipeline.
// Covers a broad selection of pipeline stages, expression operators, and
// group accumulators. The features exercised here are the subset listed in
// documentdb-local/functional-tests/config/allowlist.yml so they stay green
// across PG 15-18.

const TEST_FILE = '04-aggregation';
const DB_NAME = 'it_04_aggregation';

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
function assertApproxEq(actual, expected, tol, msg) {
  if (typeof actual !== 'number') {
    throw new Error((msg || 'assertApproxEq') + ': not a number: ' + actual);
  }
  if (Math.abs(actual - expected) > tol) {
    throw new Error((msg || 'assertApproxEq') + ': expected ' + expected +
      ' +/- ' + tol + ', got ' + actual);
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

const sales = testDb.sales;
sales.insertMany([
  { _id: 1, region: 'west', product: 'apple',  qty: 3,  price: 1.0, date: new Date('2024-01-15') },
  { _id: 2, region: 'west', product: 'banana', qty: 5,  price: 0.5, date: new Date('2024-02-10') },
  { _id: 3, region: 'east', product: 'apple',  qty: 10, price: 1.2, date: new Date('2024-02-20') },
  { _id: 4, region: 'east', product: 'cherry', qty: 7,  price: 2.0, date: new Date('2024-03-05') },
  { _id: 5, region: 'south', product: 'apple', qty: 2,  price: 1.5, date: new Date('2024-03-22') },
]);

// ---------------------------------------------------------------------------
// Stages: $match, $project, $sort, $skip, $limit
// ---------------------------------------------------------------------------

check('$match filters by predicate', () => {
  const r = sales.aggregate([{ $match: { region: 'west' } }]).toArray();
  assertEq(r.length, 2);
});

check('$project with inclusion + computed field', () => {
  const r = sales.aggregate([
    { $match: { _id: 1 } },
    { $project: { _id: 0, product: 1, total: { $multiply: ['$qty', '$price'] } } },
  ]).toArray();
  assertEq(r.length, 1);
  assertDeepEq(r[0], { product: 'apple', total: 3 });
});

check('$sort + $skip + $limit paginate results', () => {
  const r = sales.aggregate([
    { $sort: { qty: 1 } },
    { $skip: 1 },
    { $limit: 2 },
  ]).toArray();
  assertEq(r.length, 2);
  assertEq(r[0]._id, 1);
  assertEq(r[1]._id, 2);
});

check('$count returns a single document with the count', () => {
  const r = sales.aggregate([{ $count: 'n' }]).toArray();
  assertEq(r.length, 1);
  assertEq(r[0].n, 5);
});

// ---------------------------------------------------------------------------
// $unwind variants
// ---------------------------------------------------------------------------

check('$unwind expands an array field', () => {
  const c = testDb.with_arrays;
  c.insertMany([
    { _id: 1, tags: ['a', 'b', 'c'] },
    { _id: 2, tags: [] },
  ]);
  const r = c.aggregate([{ $unwind: '$tags' }]).toArray();
  assertEq(r.length, 3);
});

check('$unwind with preserveNullAndEmptyArrays keeps empty arrays', () => {
  const c = testDb.with_arrays;
  const r = c.aggregate([
    { $unwind: { path: '$tags', preserveNullAndEmptyArrays: true } },
  ]).toArray();
  assertEq(r.length, 4, 'one extra row for the empty array');
});

check('$unwind with includeArrayIndex adds the index field', () => {
  const c = testDb.with_arrays;
  const r = c.aggregate([
    { $match: { _id: 1 } },
    { $unwind: { path: '$tags', includeArrayIndex: 'idx' } },
    { $sort: { idx: 1 } },
  ]).toArray();
  assertDeepEq(r.map((x) => Number(x.idx)), [0, 1, 2]);
});

// ---------------------------------------------------------------------------
// $addFields, $set, $unset, $replaceRoot
// ---------------------------------------------------------------------------

check('$addFields injects a new field', () => {
  const r = sales.aggregate([
    { $match: { _id: 1 } },
    { $addFields: { total: { $multiply: ['$qty', '$price'] } } },
  ]).toArray();
  assertEq(r[0].total, 3);
});

check('$set is an alias for $addFields', () => {
  const r = sales.aggregate([
    { $match: { _id: 2 } },
    { $set: { total: { $multiply: ['$qty', '$price'] } } },
  ]).toArray();
  assertEq(r[0].total, 2.5);
});

check('$unset drops fields', () => {
  const r = sales.aggregate([
    { $match: { _id: 1 } },
    { $unset: ['price', 'date'] },
  ]).toArray();
  assert(!('price' in r[0]) && !('date' in r[0]),
    'price and date should be removed: ' + JSON.stringify(r[0]));
});

check('$replaceRoot promotes an embedded document', () => {
  const c = testDb.with_nested;
  c.insertOne({ _id: 1, inner: { a: 1, b: 2 } });
  const r = c.aggregate([{ $replaceRoot: { newRoot: '$inner' } }]).toArray();
  assertDeepEq(r[0], { a: 1, b: 2 });
});

// ---------------------------------------------------------------------------
// $group with various accumulators
// ---------------------------------------------------------------------------

check('$group with $sum and $avg', () => {
  const r = sales.aggregate([
    {
      $group: {
        _id: '$region',
        totalQty: { $sum: '$qty' },
        avgQty: { $avg: '$qty' },
      },
    },
    { $sort: { _id: 1 } },
  ]).toArray();
  const east = r.find((x) => x._id === 'east');
  assertEq(east.totalQty, 17);
  assertApproxEq(east.avgQty, 8.5, 1e-9);
});

check('$group with $min and $max', () => {
  const r = sales.aggregate([
    {
      $group: {
        _id: null,
        minQty: { $min: '$qty' },
        maxQty: { $max: '$qty' },
      },
    },
  ]).toArray();
  assertEq(r[0].minQty, 2);
  assertEq(r[0].maxQty, 10);
});

check('$group with $first and $last after $sort', () => {
  const r = sales.aggregate([
    { $sort: { qty: 1 } },
    {
      $group: {
        _id: null,
        smallest: { $first: '$product' },
        largest: { $last: '$product' },
      },
    },
  ]).toArray();
  assertEq(r[0].smallest, 'apple');
  assertEq(r[0].largest, 'apple');
});

check('$group with $push collects values', () => {
  const r = sales.aggregate([
    { $sort: { _id: 1 } },
    { $group: { _id: '$region', products: { $push: '$product' } } },
    { $sort: { _id: 1 } },
  ]).toArray();
  const east = r.find((x) => x._id === 'east');
  assertDeepEq(east.products.sort(), ['apple', 'cherry']);
});

check('$group with $addToSet deduplicates values', () => {
  const r = sales.aggregate([
    { $group: { _id: null, products: { $addToSet: '$product' } } },
  ]).toArray();
  assertDeepEq(r[0].products.sort(), ['apple', 'banana', 'cherry']);
});

check('$group with $stdDevPop and $stdDevSamp produce numbers', () => {
  const r = sales.aggregate([
    {
      $group: {
        _id: null,
        sdp: { $stdDevPop: '$qty' },
        sds: { $stdDevSamp: '$qty' },
      },
    },
  ]).toArray();
  assert(typeof r[0].sdp === 'number' && r[0].sdp >= 0,
    '$stdDevPop should be a non-negative number: ' + r[0].sdp);
  assert(typeof r[0].sds === 'number' && r[0].sds >= 0,
    '$stdDevSamp should be a non-negative number: ' + r[0].sds);
});

// ---------------------------------------------------------------------------
// $facet, $bucket, $bucketAuto, $sortByCount, $sample
// ---------------------------------------------------------------------------

check('$facet runs multiple sub-pipelines in parallel', () => {
  const r = sales.aggregate([
    {
      $facet: {
        byRegion: [{ $group: { _id: '$region', n: { $sum: 1 } } }],
        total: [{ $count: 'n' }],
      },
    },
  ]).toArray();
  assertEq(r.length, 1);
  assert(Array.isArray(r[0].byRegion) && r[0].byRegion.length === 3,
    'byRegion should have 3 entries');
  assertEq(r[0].total[0].n, 5);
});

check('$bucket groups numeric values into explicit boundaries', () => {
  const r = sales.aggregate([
    {
      $bucket: {
        groupBy: '$qty',
        boundaries: [0, 5, 10, 20],
        default: 'other',
        output: { n: { $sum: 1 } },
      },
    },
    { $sort: { _id: 1 } },
  ]).toArray();
  // 0..4: qty in {3, 2}; 5..9: qty in {5, 7}; 10..19: qty in {10}
  assertDeepEq(r.map((x) => ({ b: x._id, n: x.n })), [
    { b: 0, n: 2 },
    { b: 5, n: 2 },
    { b: 10, n: 1 },
  ]);
});

check('$bucketAuto splits into N approximately equal buckets', () => {
  const r = sales.aggregate([
    { $bucketAuto: { groupBy: '$qty', buckets: 2 } },
  ]).toArray();
  assertEq(r.length, 2);
  const total = r.reduce((acc, b) => acc + b.count, 0);
  assertEq(total, 5);
});

check('$sortByCount returns counts in descending order', () => {
  const r = sales.aggregate([{ $sortByCount: '$region' }]).toArray();
  assertEq(r.length, 3);
  // Counts must be monotonically non-increasing.
  for (let i = 1; i < r.length; i++) {
    assert(r[i - 1].count >= r[i].count,
      'counts should be non-increasing: ' + JSON.stringify(r));
  }
});

check('$sample returns at most size docs', () => {
  const r = sales.aggregate([{ $sample: { size: 3 } }]).toArray();
  assert(r.length <= 3, 'sample size should be respected');
});

// ---------------------------------------------------------------------------
// $lookup
// ---------------------------------------------------------------------------

check('$lookup joins on a foreign field', () => {
  const products = testDb.products;
  products.insertMany([
    { _id: 'apple',  category: 'fruit' },
    { _id: 'banana', category: 'fruit' },
    { _id: 'cherry', category: 'fruit' },
  ]);
  const r = sales.aggregate([
    { $match: { _id: 1 } },
    {
      $lookup: {
        from: 'products',
        localField: 'product',
        foreignField: '_id',
        as: 'productDoc',
      },
    },
  ]).toArray();
  assertEq(r[0].productDoc.length, 1);
  assertEq(r[0].productDoc[0].category, 'fruit');
});

// ---------------------------------------------------------------------------
// Expression operators (arithmetic / string / array / date / conditional)
// ---------------------------------------------------------------------------

check('arithmetic expressions: $add / $subtract / $multiply / $divide / $mod', () => {
  const r = sales.aggregate([
    { $match: { _id: 4 } },
    {
      $project: {
        _id: 0,
        sum: { $add: ['$qty', '$price'] },
        diff: { $subtract: ['$qty', '$price'] },
        prod: { $multiply: ['$qty', '$price'] },
        quot: { $divide: ['$qty', '$price'] },
        mod3: { $mod: ['$qty', 3] },
      },
    },
  ]).toArray();
  assertApproxEq(r[0].sum, 9, 1e-9);
  assertApproxEq(r[0].diff, 5, 1e-9);
  assertApproxEq(r[0].prod, 14, 1e-9);
  assertApproxEq(r[0].quot, 3.5, 1e-9);
  assertEq(r[0].mod3, 1);
});

check('arithmetic expressions: $abs / $ceil / $floor', () => {
  const c = testDb.numbers;
  c.insertMany([{ _id: 1, n: -3.2 }]);
  const r = c.aggregate([
    { $project: { _id: 0, abs: { $abs: '$n' }, ceil: { $ceil: '$n' }, floor: { $floor: '$n' } } },
  ]).toArray();
  assertApproxEq(r[0].abs, 3.2, 1e-9);
  assertEq(r[0].ceil, -3);
  assertEq(r[0].floor, -4);
});

check('string expressions: $concat / $toUpper / $toLower / $strLenCP', () => {
  const r = sales.aggregate([
    { $match: { _id: 1 } },
    {
      $project: {
        _id: 0,
        upper: { $toUpper: '$product' },
        lower: { $toLower: '$region' },
        concat: { $concat: ['$region', ':', '$product'] },
        len: { $strLenCP: '$product' },
      },
    },
  ]).toArray();
  assertEq(r[0].upper, 'APPLE');
  assertEq(r[0].lower, 'west');
  assertEq(r[0].concat, 'west:apple');
  assertEq(r[0].len, 5);
});

check('array expressions: $size / $arrayElemAt / $concatArrays', () => {
  const c = testDb.arr_ops;
  c.insertOne({ _id: 1, a: [1, 2, 3], b: [4, 5] });
  const r = c.aggregate([
    {
      $project: {
        _id: 0,
        sz: { $size: '$a' },
        first: { $arrayElemAt: ['$a', 0] },
        joined: { $concatArrays: ['$a', '$b'] },
      },
    },
  ]).toArray();
  assertEq(r[0].sz, 3);
  assertEq(r[0].first, 1);
  assertDeepEq(r[0].joined, [1, 2, 3, 4, 5]);
});

check('date expressions: $year / $month / $dayOfMonth', () => {
  const r = sales.aggregate([
    { $match: { _id: 1 } },
    {
      $project: {
        _id: 0,
        y: { $year: '$date' },
        m: { $month: '$date' },
        d: { $dayOfMonth: '$date' },
      },
    },
  ]).toArray();
  assertEq(r[0].y, 2024);
  assertEq(r[0].m, 1);
  assertEq(r[0].d, 15);
});

check('conditional expressions: $cond / $ifNull', () => {
  const c = testDb.maybe;
  c.insertMany([
    { _id: 1, x: 10 },
    { _id: 2 },
  ]);
  const r = c.aggregate([
    { $sort: { _id: 1 } },
    {
      $project: {
        _id: 1,
        kind: { $cond: [{ $gte: ['$x', 5] }, 'big', 'small'] },
        xOrZero: { $ifNull: ['$x', 0] },
      },
    },
  ]).toArray();
  assertEq(r[0].kind, 'big');
  assertEq(r[1].xOrZero, 0);
});

testDb.dropDatabase();

print('=== ' + TEST_FILE + ' summary: ' + _passed + ' passed, ' + _failed + ' failed ===');
if (_failed > 0) {
  for (const f of _failures) print('FAILURE: ' + f.name + ': ' + f.err);
  quit(1);
}
