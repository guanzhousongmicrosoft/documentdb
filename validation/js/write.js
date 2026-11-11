// Write-path checks after an upgrade, in db "upg_w" so the "upg" fingerprint stays untouched.
const d = db.getSiblingDB('upg_w'); d.dropDatabase(); let failed = 0;
function check(name, fn) { try { const r = fn(); if (r === true) print('PASS ' + name); else { failed++; print('FAIL ' + name + ': ' + EJSON.stringify(r)); } } catch (e) { failed++; print('FAIL ' + name + ': threw ' + (e.codeName || '') + ' ' + String(e.message).slice(0, 160)); } }
check('insert 5000', () => { d.w.insertMany(Array.from({ length: 5000 }, (_, i) => ({ _id: i, n: i, u: 'u' + i, t: 'fox dog ' + i, loc: { type: 'Point', coordinates: [-122 + i / 10000, 47] }, v: [i % 5, i % 7, i % 11] }))); return d.w.countDocuments({}) === 5000; });
check('update/delete', () => d.w.updateMany({ n: { $lt: 100 } }, { $inc: { n: 100000 } }).modifiedCount === 100 && d.w.deleteMany({ n: { $gte: 100000 } }).deletedCount === 100);
check('new btree + unique index', () => !!d.w.createIndex({ n: 1 }) && !!d.w.createIndex({ u: 1 }, { unique: true }) && d.w.find({ n: 4000 }).hint('n_1').toArray().length === 1);
check('new 2dsphere index', () => !!d.w.createIndex({ loc: '2dsphere' }) && d.w.countDocuments({ loc: { $geoWithin: { $centerSphere: [[-121.9, 47], 0.001] } } }) > 0);
check('new text index', () => !!d.w.createIndex({ t: 'text' }) && d.w.countDocuments({ $text: { $search: 'fox' } }) === 4900);
check('new vector index', () => { d.runCommand({ createIndexes: 'w', indexes: [{ key: { v: 'cosmosSearch' }, name: 'v', cosmosSearchOptions: { kind: 'vector-hnsw', similarity: 'COS', dimensions: 3, m: 16, efConstruction: 64 } }] }); return d.w.aggregate([{ $search: { cosmosSearch: { vector: [1, 2, 3], path: 'v', k: 5 } } }]).toArray().length === 5; });
check('unique enforced', () => { try { d.w.insertOne({ _id: 99999, u: 'u500' }); return 'no error'; } catch (e) { return e.code === 11000; } });
check('transaction', () => { const s = d.getMongo().startSession(); const c = s.getDatabase('upg_w').tx; d.createCollection('tx'); s.startTransaction(); c.insertOne({ _id: 1 }); s.commitTransaction(); s.startTransaction(); c.insertOne({ _id: 2 }); s.abortTransaction(); s.endSession(); return d.tx.countDocuments({}) === 1; });
check('write to upgraded collection', () => { const u = db.getSiblingDB('upg').scratch; u.insertOne({ _id: 'w', at: 1 }); const ok = u.findOne({ _id: 'w' }).at === 1; u.drop(); return ok; });
check('index on upgraded collection', () => { const I = db.getSiblingDB('upg').items; I.createIndex({ i32: 1 }, { name: 'tmp_i32' }); const ok = I.find({ i32: 777 }).hint('tmp_i32').toArray().length === 1; I.dropIndex('tmp_i32'); return ok; });
check('drop collection', () => d.w.drop() === true);
print('WRITE_DONE failed=' + failed); quit(failed ? 1 : 0);
