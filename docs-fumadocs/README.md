# Wrappers Documentation (FumaDocs)

This is the documentation site for Supabase Wrappers, built with [FumaDocs](https://fumadocs.dev) and Next.js.

## Development

```bash
# Install dependencies
npm install

# Start development server
npm run dev
```

Open [http://localhost:3000/wrappers](http://localhost:3000/wrappers) to view the docs.

## Build

```bash
# Build for production
npm run build
```

The static site will be generated in the `out/` directory.

## Structure

```
docs-fumadocs/
├── app/                    # Next.js App Router pages
│   ├── docs/              # Documentation routes
│   └── layout.tsx         # Root layout
├── content/docs/          # MDX documentation content
│   ├── catalog/           # FDW integration docs
│   ├── guides/            # User guides
│   └── contributing/      # Contributor guides
├── components/            # React components
├── lib/                   # Utility functions
└── public/               # Static assets
```

## Migrating Content

To re-run the migration from MkDocs:

```bash
node ../scripts/migrate-to-fumadocs.js
```

This script converts:
- MkDocs admonitions to FumaDocs Callout components
- MkDocs tabs to FumaDocs Tabs components
- Internal `.md` links to route-based links
- Front matter format
