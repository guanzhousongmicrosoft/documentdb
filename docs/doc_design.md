# Design Doc: Versioned Documentation with MkDocs and GitHub Pages

## Overview

This document proposes adopting MkDocs with GitHub Pages to manage, version, and host documentation for the DocumentDB project. MkDocs is a powerful, easy-to-use, open-source documentation generator that uses Markdown files to create a structured, visually appealing, and maintainable documentation site.

## Why MkDocs?

* **Markdown-based**: Simple, human-readable, and easy to maintain.
* **Manual versioning**: Clear directory-based versioning strategy.
* **Free and Open Source**: Permissive BSD-2-Clause license.
* **Seamless integration**: Works perfectly with GitHub Pages for hosting.
* **Flexible structure**: Supports nested documentation structures.

## Folder Structure

```plaintext
DocumentDB/
├── docs/
│   ├── v1/
│   │   ├── getting-started.md
│   │   ├── prebuild-image.md
│   │   └── packaging.md
│   ├── v2/
│   │   ├── getting-started.md
│   │   ├── prebuild-image.md
│   │   └── packaging.md
│   └── (new version folders)
├── mkdocs.yml
└── .github/
    └── workflows/
        └── deploy-docs.yml
```

* Each version's documentation lives in its own clearly marked subdirectory (`docs/v1`, `docs/v2`, etc.).
* The MkDocs configuration (`mkdocs.yml`) explicitly manages navigation and versioning.

## Version Management

Versioning is handled manually by creating a new folder (`vX.X`) inside the `docs/` directory and updating the navigation structure in `mkdocs.yml`. This approach provides full control and avoids the need for external tools.

* Example versions: `docs/v1`, `docs/v2`
* The default version can be set by pointing the `Home:` entry in `mkdocs.yml` to the desired `index.md` file.

## Hosting

Documentation will be hosted via GitHub Pages:

```
https://<org-or-user>.github.io/<repo-name>/
```

Example:

```
https://guanzhousongmicrosoft.github.io/documentdb/
```

* Free, secure, and automatically updated with each commit.

## Automated Deployment via GitHub Actions

Automated builds and deployment are configured through GitHub Actions (`deploy-docs.yml`):

```yaml
name: Deploy MkDocs
on:
  push:
    branches:
      - main
      - mkdocs
jobs:
  deploy:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: actions/setup-python@v5
        with:
          python-version: 3.x
      - run: pip install mkdocs mkdocs-material
      - run: mkdocs gh-deploy --clean --force
```

* Every push to `main` or `mkdocs` builds and publishes the site to the `gh-pages` branch.
* `--clean` ensures outdated files are removed, and `--force` bypasses confirmation prompts.

## Adding or Modifying Content

### Adding a New Version:

1. Duplicate an existing version folder (e.g., copy `docs/v2` to `docs/v3`).
2. Update content and titles in the new folder.
3. Update `mkdocs.yml` to include the new version in the navigation.
4. Commit changes and push — GitHub Actions will auto-deploy.

### Modifying Existing Docs:

1. Edit Markdown files in the relevant `docs/vX.X/` folder.
2. Commit changes.
3. Push to GitHub — the site will auto-rebuild and deploy.

## Integrating with GitHub Wiki

The main documentation site will be hosted on GitHub Pages (`github.io`). The GitHub Wiki page can include a short project overview and a link to the hosted documentation site to direct users to the full content.

## Next Steps

1. Verify whether the Microsoft repository can host a static page at `microsoft.github.io/documentdb`.
2. Request access to the GitHub repository to test and deploy the MkDocs solution.
3. (Optional) Multiple languages support

---

This approach will significantly improve documentation management, ensuring clarity, accessibility, and a professional appearance while minimizing maintenance overhead.
