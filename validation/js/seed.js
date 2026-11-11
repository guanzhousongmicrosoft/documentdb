// Deterministic upgrade dataset in db "upg". Optional features are recorded so both versions compare like for like.
const d = db.getSiblingDB('upg'); d.dropDatabase();
const N = Number(process.env.SEED_N || 300000);
const feats = {};
function batch(coll, n, gen, size) {
    size = size || 5000;
    for (let i = 0; i < n; i += size) {
        const a = []; for (let j = i; j < Math.min(n, i + size); j++) a.push(gen(j));
        coll.insertMany(a, { ordered: false });
    }
}
function opt(name, fn) { try { fn(); feats[name] = 'ok'; } catch (e) { feats[name] = 'ERR ' + (e.codeName || e.code || '') ; } }
const hex = (i, w) => i.toString(16).padStart(w, '0');
batch(d.items, N, i => ({
    _id: i, n: i, u: 'u' + i, cat: 'c' + (i % 50), grp: i % 1000, tags: ['t' + (i % 7), 's' + (i % 13)],
    nested: { a: i % 17, b: { c: 'x' + (i % 29) }, arr: [{ k: i % 5, v: 'v' + (i % 11) }, { k: (i + 1) % 5 }] },
    price: NumberDecimal((i % 1000) + '.25'), big: NumberLong('9007199254740993'), i32: NumberInt(i % 2147483647),
    dbl: i / 7, when: new Date(1700000000000 + i * 1000), flag: i % 3 === 0,
    ...(i % 5 === 0 ? { opt: null } : i % 5 === 1 ? {} : { opt: i }),
    oid: new ObjectId(hex(i, 24)), uuid: UUID('00000000-0000-4000-8000-' + hex(i, 12)),
    bin: new Binary(Buffer.from('b' + i)), ts: new Timestamp({ t: 1700000000 + (i % 1000), i: 1 }),
    uni: 'héllo-世界-' + (i % 97), s: 'payload-' + 'x'.repeat(i % 64), empty: i % 2 ? [] : {},
}));
d.items.createIndex({ n: 1 });
d.items.createIndex({ cat: 1, n: -1 });
d.items.createIndex({ u: 1 }, { unique: true });
d.items.createIndex({ tags: 1 });
d.items.createIndex({ 'nested.b.c': 1 });
opt('idx_hashed', () => d.items.createIndex({ grp: 'hashed' }));
opt('idx_partial', () => d.items.createIndex({ price: 1 }, { partialFilterExpression: { flag: true }, name: 'price_partial' }));
opt('idx_sparse', () => d.items.createIndex({ opt: 1 }, { sparse: true, name: 'opt_sparse' }));
opt('idx_wildcard', () => d.items.createIndex({ 'nested.$**': 1 }, { name: 'nested_wild' }));
opt('idx_collation', () => d.items.createIndex({ uni: 1 }, { collation: { locale: 'en', strength: 2 }, name: 'uni_ci' }));
const G = Math.min(N, 50000);
batch(d.geo, G, i => ({ _id: i, loc: { type: 'Point', coordinates: [-122 + (i % 1000) / 1000, 47 + (i % 500) / 1000] }, pos: [i % 180, (i % 90)], n: i }));
d.geo.createIndex({ loc: '2dsphere' });
opt('idx_2d', () => d.geo.createIndex({ pos: '2d' }));
const W = ['quick', 'brown', 'fox', 'lazy', 'dog', 'jumps', 'sleeping', 'river', 'mountain', 'coffee', 'database', 'index'];
batch(d.txt, G, i => ({ _id: i, body: W[i % 12] + ' ' + W[(i * 7) % 12] + ' ' + W[(i * 5 + 3) % 12] + ' doc' + i, title: W[(i * 3) % 12] }));
d.txt.createIndex({ body: 'text', title: 'text' }, { weights: { title: 5 }, name: 'txt_idx' });
const V = Math.min(N, 20000);
const vec = i => Array.from({ length: 8 }, (_, k) => ((i * (k + 3)) % 101) / 101);
batch(d.vec, V, i => ({ _id: i, v: vec(i), n: i }));
opt('idx_hnsw', () => { const r = d.runCommand({ createIndexes: 'vec', indexes: [{ key: { v: 'cosmosSearch' }, name: 'v_hnsw', cosmosSearchOptions: { kind: 'vector-hnsw', similarity: 'COS', dimensions: 8, m: 16, efConstruction: 64 } }] }); if (!r.ok) throw r; });
batch(d.vec2, V, i => ({ _id: i, v: vec(i), n: i }));
opt('idx_ivf', () => { const r = d.runCommand({ createIndexes: 'vec2', indexes: [{ key: { v: 'cosmosSearch' }, name: 'v_ivf', cosmosSearchOptions: { kind: 'vector-ivf', similarity: 'L2', dimensions: 8, numLists: 20 } }] }); if (!r.ok) throw r; });
batch(d.ttl, 1000, i => ({ _id: i, when: new Date(4102444800000 + i * 1000) }));
d.ttl.createIndex({ when: 1 }, { expireAfterSeconds: 3600 });
const big = 'z'.repeat(2 * 1024 * 1024);
for (let i = 0; i < 20; i++) d.blob.insertOne({ _id: i, s: big + i, n: i });
d.cats.insertMany(Array.from({ length: 50 }, (_, i) => ({ _id: 'c' + i, label: 'Category ' + i })));
opt('view', () => d.createView('items_c1', 'items', [{ $match: { cat: 'c1' } }]));
opt('validator', () => d.createCollection('valid', { validator: { $jsonSchema: { required: ['a'] } } }) && d.valid.insertOne({ _id: 1, a: 1 }));
d.meta.insertOne({ _id: 'feats', feats, N });
print('SEED_DONE ' + EJSON.stringify(feats));
