import Link from 'next/link';

export default function HomePage() {
  return (
    <main className="flex h-screen flex-col items-center justify-center text-center px-4">
      <h1 className="text-4xl font-bold mb-4">Wrappers</h1>
      <p className="text-lg text-muted-foreground mb-8 max-w-2xl">
        Postgres Foreign Data Wrappers (FDW) to connect your database to external systems.
        Query and join data from Airtable, BigQuery, Stripe, Firebase, S3, and more directly from Postgres.
      </p>
      <div className="flex gap-4">
        <Link
          href="/docs"
          className="inline-flex items-center justify-center rounded-md bg-primary px-6 py-3 text-sm font-medium text-primary-foreground shadow transition-colors hover:bg-primary/90"
        >
          Get Started
        </Link>
        <Link
          href="/docs/catalog"
          className="inline-flex items-center justify-center rounded-md border border-input bg-background px-6 py-3 text-sm font-medium shadow-sm transition-colors hover:bg-accent hover:text-accent-foreground"
        >
          View Catalog
        </Link>
      </div>
    </main>
  );
}
