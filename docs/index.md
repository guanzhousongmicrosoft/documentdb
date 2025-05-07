# Welcome to DocumentDB

**DocumentDB** is a fully open-source document-oriented database engine, built on PostgreSQL and designed to power vCore-based Azure Cosmos DB for MongoDB.

It supports seamless CRUD operations on BSON data types, full-text search, geospatial queries, and vector embeddings — all within the robust PostgreSQL ecosystem.


## Get Start Here

[Getting Start with DocumentDB](v2/documentdb.md)

---

## 🚀 Features

- Native PostgreSQL extension with BSON support
- Powerful CRUD and indexing capabilities
- Support for full-text search, geospatial data, and vector workloads
- Fully open-source under the [MIT License](https://opensource.org/license/mit)
- On-premises and cloud-ready deployment

---

## 🧱 Components

- `pg_documentdb_core` – PostgreSQL extension for BSON type and operations
- `pg_documentdb` – Public API layer enabling document-oriented access

---

## 🐳 Quick Start with Docker

```bash
git clone https://github.com/microsoft/documentdb.git
cd documentdb
docker build -f .devcontainer/Dockerfile -t documentdb .
docker run -v $(pwd):/home/documentdb/code -it documentdb /bin/bash
make && sudo make install
