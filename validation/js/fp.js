// Fingerprint of db "upg": hard = must be identical across an upgrade, soft = reported when different.
const crypto = require('crypto'), fs = require('fs');
const d = db.getSiblingDB('upg'); const out = { hard: {}, soft: {} };
function hc(cur) { const m = crypto.createHash('sha256'); let n = 0; cur.forEach(x => { m.update(EJSON.stringify(x, { relaxed: false })); n++; }); return n + ':' + m.digest('hex').slice(0, 20); }
function q(sec, name, fn) { try { out[sec][name] = fn(); } catch (e) { out[sec][name] = 'ERR ' + (e.codeName || e.code || String(e.message).slice(0, 60)); } }
const colls = d.getCollectionInfos().map(c => c.name + ':' + c.type).sort();
out.hard.collections = colls;
for (const ci of d.getCollectionInfos().filter(c => c.type === 'collection')) {
    const c = d.getCollection(ci.name);
    q('hard', 'count.' + ci.name, () => c.countDocuments({}));
    q('hard', 'scan.' + ci.name, () => hc(c.find({}).sort({ _id: 1 })));
    q('hard', 'indexes.' + ci.name, () => c.getIndexes().map(i => EJSON.stringify({ name: i.name, key: i.key, unique: i.unique, sparse: i.sparse, pfe: i.partialFilterExpression, ttl: i.expireAfterSeconds, cso: i.cosmosSearchOptions, coll: i.collation && i.collation.locale, w: i.weights })).sort());
    q('soft', 'indexes_raw.' + ci.name, () => c.getIndexes().map(i => EJSON.stringify(i)).sort());
}
const I = d.items, ids = cur => hc(cur.sort({ _id: 1 }).project({ _id: 1 }));
const hinted = {
    n_1: { n: { $gte: 1000, $lt: 3000 } }, 'cat_1_n_-1': { cat: 'c7', n: { $lt: 50000 } }, u_1: { u: { $in: ['u5', 'u77', 'u4242'] } },
    tags_1: { tags: 's4', n: { $lt: 20000 } }, 'nested.b.c_1': { 'nested.b.c': 'x3', n: { $lt: 20000 } }, grp_hashed: { grp: 123 },
    price_partial: { flag: true, price: { $lt: NumberDecimal('20') }, n: { $lt: 50000 } }, opt_sparse: { opt: { $gte: 100, $lt: 2000 } },
    nested_wild: { 'nested.a': 3, n: { $lt: 20000 } },
};
for (const [h, f] of Object.entries(hinted)) {
    q('hard', 'hint.' + h, () => ids(I.find(f).hint(h)));
    q('hard', 'nohint.' + h, () => ids(I.find(f)));
    q('soft', 'explain.' + h, () => EJSON.stringify(I.find(f).explain()).includes(h));
}
q('hard', 'collation', () => ids(I.find({ uni: 'HÉLLO-世界-5', n: { $lt: 20000 } }).collation({ locale: 'en', strength: 2 })));
q('hard', 'types', () => hc(I.find({ _id: { $in: [0, 1, 2, 3, 4, 5, 99999] } }).sort({ _id: 1 })));
q('hard', 'sort_limit', () => hc(I.find({ cat: 'c3' }).sort({ n: -1 }).limit(50)));
q('hard', 'range_dec', () => I.countDocuments({ price: { $gte: NumberDecimal('500.25'), $lt: NumberDecimal('510') } }));
q('hard', 'null_missing', () => [I.countDocuments({ opt: null }), I.countDocuments({ opt: { $exists: false } }), I.countDocuments({ opt: { $type: 'null' } })]);
q('hard', 'elemMatch', () => I.countDocuments({ 'nested.arr': { $elemMatch: { k: 2, v: 'v4' } } }));
q('hard', 'regex', () => I.countDocuments({ u: /^u12/ }));
q('hard', 'distinct', () => I.distinct('cat').length + ':' + I.distinct('tags').sort().join(','));
q('hard', 'agg.group', () => hc(I.aggregate([{ $group: { _id: '$cat', c: { $sum: 1 }, mx: { $max: '$n' }, av: { $avg: '$grp' }, sm: { $sum: '$price' } } }, { $sort: { _id: 1 } }])));
q('hard', 'agg.lookup', () => hc(I.aggregate([{ $match: { n: { $lt: 200 } } }, { $lookup: { from: 'cats', localField: 'cat', foreignField: '_id', as: 'c' } }, { $project: { n: 1, 'c.label': 1 } }, { $sort: { _id: 1 } }])));
q('hard', 'agg.facet', () => hc(I.aggregate([{ $match: { n: { $lt: 20000 } } }, { $facet: { t: [{ $unwind: '$tags' }, { $group: { _id: '$tags', c: { $sum: 1 } } }, { $sort: { _id: 1 } }], b: [{ $bucket: { groupBy: '$n', boundaries: [0, 5000, 10000, 20000], output: { c: { $sum: 1 } } } }] } }])));
q('hard', 'agg.window', () => hc(I.aggregate([{ $match: { cat: 'c2', n: { $lt: 20000 } } }, { $setWindowFields: { sortBy: { n: 1 }, output: { rn: { $documentNumber: {} }, run: { $sum: '$grp', window: { documents: ['unbounded', 'current'] } } } } }, { $project: { rn: 1, run: 1 } }, { $sort: { _id: 1 } }])));
q('hard', 'agg.date', () => hc(I.aggregate([{ $match: { n: { $lt: 5000 } } }, { $group: { _id: { $dateToString: { format: '%Y-%m-%d %H', date: '$when' } }, c: { $sum: 1 } } }, { $sort: { _id: 1 } }])));
q('hard', 'geo.near', () => hc(d.geo.find({ loc: { $near: { $geometry: { type: 'Point', coordinates: [-121.9, 47.1] }, $maxDistance: 1500 } } }).project({ _id: 1 }).limit(100)));
q('hard', 'geo.within', () => d.geo.countDocuments({ loc: { $geoWithin: { $centerSphere: [[-121.5, 47.25], 0.001] } } }));
q('hard', 'geo.2d', () => d.geo.countDocuments({ pos: { $geoWithin: { $box: [[10, 10], [20, 20]] } } }));
q('hard', 'text.count', () => [d.txt.countDocuments({ $text: { $search: 'fox' } }), d.txt.countDocuments({ $text: { $search: 'coffee database' } })]);
q('hard', 'text.ids', () => hc(d.txt.find({ $text: { $search: 'mountain' } }).project({ _id: 1 }).sort({ _id: 1 })));
q('soft', 'vec.hnsw', () => d.vec.aggregate([{ $search: { cosmosSearch: { vector: [0.1, 0.2, 0.3, 0.4, 0.5, 0.6, 0.7, 0.8], path: 'v', k: 10 } } }, { $project: { _id: 1 } }]).toArray().map(x => x._id).join(','));
q('soft', 'vec.ivf', () => d.vec2.aggregate([{ $search: { cosmosSearch: { vector: [0.1, 0.2, 0.3, 0.4, 0.5, 0.6, 0.7, 0.8], path: 'v', k: 10 } } }, { $project: { _id: 1 } }]).toArray().map(x => x._id).join(','));
q('hard', 'vec.hnsw.n', () => d.vec.aggregate([{ $search: { cosmosSearch: { vector: [0.9, 0.1, 0.9, 0.1, 0.9, 0.1, 0.9, 0.1], path: 'v', k: 10 } } }, { $project: { _id: 1 } }]).toArray().length);
q('hard', 'vec.ivf.n', () => d.vec2.aggregate([{ $search: { cosmosSearch: { vector: [0.9, 0.1, 0.9, 0.1, 0.9, 0.1, 0.9, 0.1], path: 'v', k: 10 } } }, { $project: { _id: 1 } }]).toArray().length);
q('hard', 'view', () => d.items_c1.countDocuments({}));
q('hard', 'blob', () => d.blob.find({}).sort({ _id: 1 }).toArray().map(x => x.s.length).join(','));
q('hard', 'ttl.count', () => d.ttl.countDocuments({}));
q('hard', 'feats', () => EJSON.stringify(d.meta.findOne({ _id: 'feats' })));
fs.writeFileSync(process.env.FP_OUT || '/tmp/fp.json', JSON.stringify(out, Object.keys(out).concat(Object.keys(out.hard), Object.keys(out.soft)).sort(), 1));
print('FP_DONE hard=' + Object.keys(out.hard).length + ' errs=' + Object.values(out.hard).filter(v => String(v).startsWith('ERR')).length);
