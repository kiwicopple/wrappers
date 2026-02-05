# FumaDocs Migration Plan

This document outlines the plan to migrate the Wrappers documentation from MkDocs Material to FumaDocs.

## Current State Analysis

### Existing Documentation System
- **Framework**: MkDocs with Material theme
- **Location**: `/docs/` directory
- **Deployment**: GitHub Pages at `https://supabase.github.io/wrappers`
- **Total Files**: 45 markdown files (~14,600 lines)

### Documentation Structure
```
docs/
├── assets/              # 13 images (PNG, SVG, ICO)
├── catalog/             # 28 FDW integration docs
│   └── wasm/           # WASM wrapper index
├── contributing/        # 3 contributor guides
├── guides/              # 11 user/developer guides
├── stylesheets/         # Custom CSS
├── index.md            # Homepage
└── tags.md             # Auto-generated tags index
```

### Features Currently in Use
| Feature | MkDocs Syntax | Usage Count |
|---------|---------------|-------------|
| Admonitions | `!!! note/warning/info` | 25+ instances |
| Tabbed content | `=== "Tab Title"` | 20+ files |
| Code blocks | ` ```sql ` | 400+ blocks |
| Tables | Standard markdown | Extensive |
| Front matter | YAML with tags | All files |
| Internal links | Relative markdown links | Throughout |

---

## Migration Tasks

### Phase 1: Project Setup

#### 1.1 Initialize Next.js Project
- [ ] Create new Next.js 14+ app with App Router
- [ ] Choose package manager (npm/pnpm/yarn)
- [ ] Configure TypeScript

#### 1.2 Install FumaDocs Dependencies
```bash
npm install fumadocs-ui fumadocs-core fumadocs-mdx
npm install -D @types/mdx
```

#### 1.3 Configure FumaDocs
- [ ] Create `source.config.ts` for content configuration
- [ ] Set up `next.config.mjs` with MDX support
- [ ] Configure `tailwind.config.js` with FumaDocs preset

#### 1.4 Project Structure
Create the following structure:
```
wrappers-docs/
├── app/
│   ├── layout.tsx           # Root layout with FumaDocs provider
│   ├── page.tsx             # Homepage
│   └── docs/
│       └── [[...slug]]/
│           └── page.tsx     # Dynamic docs route
├── content/
│   └── docs/                # Migrated MDX files
│       ├── catalog/
│       ├── guides/
│       └── contributing/
├── components/              # Custom MDX components
├── public/
│   └── assets/             # Migrated images
├── source.config.ts
├── next.config.mjs
└── tailwind.config.js
```

---

### Phase 2: Content Migration

#### 2.1 Convert Markdown to MDX
All `.md` files need to be converted to `.mdx`:

| Current Path | New Path |
|--------------|----------|
| `docs/index.md` | `content/docs/index.mdx` |
| `docs/catalog/*.md` | `content/docs/catalog/*.mdx` |
| `docs/guides/*.md` | `content/docs/guides/*.mdx` |
| `docs/contributing/*.md` | `content/docs/contributing/*.mdx` |

#### 2.2 Front Matter Migration
Convert MkDocs front matter to FumaDocs format:

**Before (MkDocs):**
```yaml
---
source:
documentation:
author: supabase
tags:
  - native
  - official
---
```

**After (FumaDocs):**
```yaml
---
title: Airtable
description: Connect to Airtable from PostgreSQL
icon: Database
---
```

#### 2.3 Admonition Syntax Migration
Convert MkDocs admonitions to FumaDocs Callout components:

**Before (MkDocs):**
```markdown
!!! warning "Performance Consideration"
    For large Airtable bases, consider using views...
```

**After (FumaDocs):**
```mdx
<Callout type="warn" title="Performance Consideration">
  For large Airtable bases, consider using views...
</Callout>
```

Mapping:
| MkDocs | FumaDocs |
|--------|----------|
| `!!! note` | `<Callout type="info">` |
| `!!! warning` | `<Callout type="warn">` |
| `!!! info` | `<Callout type="info">` |
| `!!! danger` | `<Callout type="error">` |

#### 2.4 Tabbed Content Migration
Convert MkDocs tabs to FumaDocs Tab components:

**Before (MkDocs):**
```markdown
=== "With Vault"

    ```sql
    create server airtable_server
      foreign data wrapper airtable_wrapper
      options (api_key_id '<key_ID>');
    ```

=== "Without Vault"

    ```sql
    create server airtable_server
      foreign data wrapper airtable_wrapper
      options (api_key '<your_api_key>');
    ```
```

**After (FumaDocs):**
```mdx
<Tabs items={['With Vault', 'Without Vault']}>
  <Tab value="With Vault">
    ```sql
    create server airtable_server
      foreign data wrapper airtable_wrapper
      options (api_key_id '<key_ID>');
    ```
  </Tab>
  <Tab value="Without Vault">
    ```sql
    create server airtable_server
      foreign data wrapper airtable_wrapper
      options (api_key '<your_api_key>');
    ```
  </Tab>
</Tabs>
```

#### 2.5 Code Block Migration
- FumaDocs uses Shiki for syntax highlighting (compatible)
- Add title/filename support where needed: ` ```sql title="Create Server" `
- Line highlighting syntax may differ

#### 2.6 Link Migration
Update internal links from `.md` to route-based paths:

**Before:**
```markdown
[Create WASM Wrapper](../guides/create-wasm-wrapper.md)
```

**After:**
```markdown
[Create WASM Wrapper](/docs/guides/create-wasm-wrapper)
```

#### 2.7 Image Migration
- Move `docs/assets/` to `public/assets/`
- Update image references in content files

---

### Phase 3: Navigation & Structure

#### 3.1 Create meta.json Files
FumaDocs uses `meta.json` files for navigation structure:

**`content/docs/meta.json`:**
```json
{
  "title": "Wrappers",
  "pages": [
    "index",
    "---Catalog---",
    "catalog",
    "---Guides---",
    "guides",
    "---Contributing---",
    "contributing"
  ]
}
```

**`content/docs/catalog/meta.json`:**
```json
{
  "title": "Catalog",
  "pages": [
    "index",
    "---Native Wrappers---",
    "airtable",
    "auth0",
    "cognito",
    "bigquery",
    "clickhouse",
    "duckdb",
    "firebase",
    "iceberg",
    "logflare",
    "redis",
    "s3",
    "s3vectors",
    "stripe",
    "mssql",
    "---WASM Wrappers---",
    "wasm",
    "cal",
    "calendly",
    "clerk",
    "cfd1",
    "gravatar",
    "hubspot",
    "infura",
    "notion",
    "orb",
    "paddle",
    "shopify",
    "slack",
    "snowflake"
  ]
}
```

---

### Phase 4: Theming & Styling

#### 4.1 Configure Dark Theme
FumaDocs supports dark mode out of the box. Configure in `tailwind.config.js`:

```javascript
module.exports = {
  presets: [require('fumadocs-ui/tailwind-preset')],
  theme: {
    extend: {
      colors: {
        // Match current green accent
        primary: {
          DEFAULT: '#4caf50',
        },
      },
    },
  },
};
```

#### 4.2 Custom Components
Create custom MDX components as needed:

```
components/
├── Callout.tsx       # Admonition replacement
├── Tabs.tsx          # Tab component
├── CodeBlock.tsx     # Enhanced code blocks
└── Table.tsx         # Styled tables
```

#### 4.3 Migrate Custom CSS
Port relevant styles from `docs/stylesheets/extra.css`:
- IBM Plex Sans font
- Dark theme colors (#121212 background)
- Code block styling

---

### Phase 5: Features & Integrations

#### 5.1 Search Integration
Configure search (Orama recommended for static sites):
```typescript
// source.config.ts
import { defineConfig } from 'fumadocs-mdx/config';

export default defineConfig({
  // Enable search index generation
});
```

#### 5.2 Edit on GitHub Link
Configure in layout:
```typescript
<DocsLayout
  nav={{
    githubUrl: 'https://github.com/supabase/wrappers',
  }}
  sidebar={{
    // ...
  }}
/>
```

#### 5.3 Tags System
Implement tag filtering if needed (FumaDocs supports this via custom implementation)

---

### Phase 6: Deployment

#### 6.1 Build Configuration
Configure for static export in `next.config.mjs`:
```javascript
/** @type {import('next').NextConfig} */
const nextConfig = {
  output: 'export',
  basePath: '/wrappers',
};
```

#### 6.2 GitHub Actions Workflow
Create `.github/workflows/docs.yml`:
```yaml
name: Deploy Docs
on:
  push:
    branches: [main]
    paths: ['docs/**', 'content/**']

jobs:
  deploy:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: actions/setup-node@v4
        with:
          node-version: '20'
      - run: npm ci
      - run: npm run build
      - uses: peaceiris/actions-gh-pages@v3
        with:
          github_token: ${{ secrets.GITHUB_TOKEN }}
          publish_dir: ./out
```

#### 6.3 Update CNAME
Ensure `public/CNAME` contains the correct domain if using custom domain.

---

## File Migration Checklist

### Catalog (28 files)
- [ ] `catalog/index.md` - Catalog overview
- [ ] `catalog/airtable.md` - Airtable FDW
- [ ] `catalog/auth0.md` - Auth0 FDW
- [ ] `catalog/bigquery.md` - BigQuery FDW
- [ ] `catalog/cal.md` - Cal.com FDW (WASM)
- [ ] `catalog/calendly.md` - Calendly FDW (WASM)
- [ ] `catalog/cfd1.md` - Cloudflare D1 FDW (WASM)
- [ ] `catalog/clerk.md` - Clerk FDW (WASM)
- [ ] `catalog/clickhouse.md` - ClickHouse FDW
- [ ] `catalog/cognito.md` - AWS Cognito FDW
- [ ] `catalog/duckdb.md` - DuckDB FDW
- [ ] `catalog/firebase.md` - Firebase FDW
- [ ] `catalog/gravatar.md` - Gravatar FDW (WASM)
- [ ] `catalog/hubspot.md` - HubSpot FDW (WASM)
- [ ] `catalog/iceberg.md` - Iceberg FDW
- [ ] `catalog/infura.md` - Infura FDW (WASM)
- [ ] `catalog/logflare.md` - Logflare FDW
- [ ] `catalog/mssql.md` - SQL Server FDW
- [ ] `catalog/notion.md` - Notion FDW (WASM)
- [ ] `catalog/orb.md` - Orb FDW (WASM)
- [ ] `catalog/paddle.md` - Paddle FDW (WASM)
- [ ] `catalog/redis.md` - Redis FDW
- [ ] `catalog/s3.md` - S3 FDW
- [ ] `catalog/s3vectors.md` - S3 Vectors FDW
- [ ] `catalog/shopify.md` - Shopify FDW (WASM)
- [ ] `catalog/slack.md` - Slack FDW (WASM)
- [ ] `catalog/snowflake.md` - Snowflake FDW (WASM)
- [ ] `catalog/stripe.md` - Stripe FDW
- [ ] `catalog/wasm/index.md` - WASM overview

### Guides (11 files)
- [ ] `guides/installation.md` - Installing Wrappers
- [ ] `guides/updating-wrappers.md` - Updating FDWs
- [ ] `guides/removing-wrappers.md` - Removing FDWs
- [ ] `guides/security.md` - Security guide
- [ ] `guides/query-pushdown.md` - Query pushdown
- [ ] `guides/usage-statistics.md` - FDW statistics
- [ ] `guides/native-wasm.md` - Native vs WASM
- [ ] `guides/limitations.md` - Limitations
- [ ] `guides/remote-subqueries.md` - Remote subqueries
- [ ] `guides/create-wasm-wrapper.md` - Create WASM wrapper
- [ ] `guides/wasm-advanced.md` - Advanced WASM guide

### Contributing (3 files)
- [ ] `contributing/documentation.md` - Building docs
- [ ] `contributing/core.md` - Core development
- [ ] `contributing/native.md` - Native wrapper dev

### Other (3 files)
- [ ] `index.md` - Homepage
- [ ] `tags.md` - Tags index (auto-generated, may not need migration)

---

## Migration Script Outline

A migration script can automate much of the conversion:

```typescript
// scripts/migrate-to-fumadocs.ts
import fs from 'fs/promises';
import path from 'path';
import glob from 'fast-glob';

async function migrate() {
  const files = await glob('docs/**/*.md');

  for (const file of files) {
    let content = await fs.readFile(file, 'utf-8');

    // 1. Convert admonitions
    content = content.replace(
      /!!! (note|warning|info|danger) "(.*)"\n([\s\S]*?)(?=\n\n|\n!!!|$)/g,
      (_, type, title, body) => {
        const fumadocsType = { note: 'info', warning: 'warn', info: 'info', danger: 'error' }[type];
        const cleanBody = body.replace(/^    /gm, '');
        return `<Callout type="${fumadocsType}" title="${title}">\n${cleanBody}\n</Callout>`;
      }
    );

    // 2. Convert tabs
    content = convertTabs(content);

    // 3. Update links
    content = content.replace(/\.md\)/g, ')');
    content = content.replace(/\.md#/g, '#');

    // 4. Update front matter
    content = updateFrontMatter(content);

    // Write to new location
    const newPath = file.replace('docs/', 'content/docs/').replace('.md', '.mdx');
    await fs.mkdir(path.dirname(newPath), { recursive: true });
    await fs.writeFile(newPath, content);
  }
}
```

---

## Estimated Effort

| Phase | Tasks | Complexity |
|-------|-------|------------|
| Phase 1: Setup | 4 tasks | Low |
| Phase 2: Content | 45 files to convert | Medium-High |
| Phase 3: Navigation | Create meta.json files | Low |
| Phase 4: Theming | Port styles, create components | Medium |
| Phase 5: Features | Search, GitHub links, tags | Medium |
| Phase 6: Deployment | CI/CD, domain config | Low |

**Key Challenges:**
1. Tabbed content syntax conversion (20+ files)
2. Admonition syntax conversion (25+ instances)
3. Large files (Shopify: 1,290 lines, Stripe: 1,233 lines)
4. Maintaining consistent formatting across 45 files

---

## Resources

- [FumaDocs Documentation](https://fumadocs.dev)
- [FumaDocs GitHub](https://github.com/fuma-nama/fumadocs)
- [FumaDocs MDX Guide](https://fumadocs.dev/docs/mdx)
- [Next.js App Router](https://nextjs.org/docs/app)

---

## Decision Points

Before starting migration, decide on:

1. **Monorepo vs Separate Repo**: Keep docs in same repo or create separate docs repo?
2. **Deployment Target**: Continue with GitHub Pages or switch to Vercel/other?
3. **Search Provider**: Use Orama (built-in) or integrate Algolia?
4. **Custom Domain**: Keep `supabase.github.io/wrappers` or use custom domain?
5. **Migration Approach**: Big-bang migration or incremental parallel deployment?
