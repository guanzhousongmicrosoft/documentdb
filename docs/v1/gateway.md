# DocumentDB Gateway

## Overview
The DocumentDB Gateway is a RESTful API that provides a simple and efficient way to interact with the DocumentDB database. It allows users to connect to the DocumentDB through Mongosh, and perform CRUD (Create, Read, Update, Delete) operations.

## Get Started
To get started with the DocumentDB Gateway, follow these steps:
        
1. **Build the Gateway**: Build the DocumentDB Gateway using the provided Dockerfile.
    ```bash
    docker build . -f .github/containers/Build-Ubuntu/Dockerfile_gateway -t <image-tag>
    ```
2. **Run the Gateway**: Run the DocumentDB Gateway in a Docker container.
    ```bash
    docker run -dt -p 10260:10260 -e USERNAME=<username> -e PASSWORD=<password> <image-tag>
    ```
3. **Connect to the Gateway**: Use Mongosh to connect to the DocumentDB Gateway.
    ```bash
    mongosh localhost:10260 -u <username> -p <password> \
        --authenticationMechanism SCRAM-SHA-256 \
        --tls \
        --tlsAllowInvalidCertificates
    ```