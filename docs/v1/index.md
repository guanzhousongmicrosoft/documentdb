# Welcome to DocumentDB

**DocumentDB** is a fully open-source document-oriented database engine, built on PostgreSQL.

It supports seamless CRUD operations on BSON data types, full-text search, geospatial queries, and vector embeddings — all within the robust PostgreSQL ecosystem.


## Get Start Here

[Introduction](v1/documentdb.md)

[Prebuild Image](v1/prebuild-image.md)

[Packaging](v1/packaging.md)

[DocumentDB Gateway](v1/gateway.md)

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
- `pg_documentdb_gw` – Gateway for DocumentDB, providing a MongoDB interface

---

## 🐳 Quick Start with Docker
### Prebuild Image For DocumentDB
There are prebuild images available for different platforms. You can find the list of prebuild images [here](v1/prebuild-image.md).

To run the prebuild image, use the following command:
```bash
# example for Ubuntu 22.04, PostgreSQL 16, amd64
# Choose the image tag according to your configuration
docker run -dt mcr.microsoft.com/cosmosdb/ubuntu/documentdb-oss:22.04-PG16-AMD64-0.103.0
docker exec -it <container-id> bash  
```

### Prebuild Image For DocumentDB with Gateway
To run the prebuild image with the DocumentDB Gateway, use the following command:
```bash
docker run -dt -p 10260:10260 -e USERNAME=<username> -e PASSWORD=<password> ghcr.io/microsoft/documentdb/preview:test

mongosh localhost:10260 -u <username> -p <password> \
        --authenticationMechanism SCRAM-SHA-256 \
        --tls \
        --tlsAllowInvalidCertificates
```

### Build DocumentDB from Source
```bash
git clone https://github.com/microsoft/documentdb.git
cd documentdb
docker build -f .devcontainer/Dockerfile -t documentdb .
docker run -v $(pwd):/home/documentdb/code -it documentdb /bin/bash
make && sudo make install
```