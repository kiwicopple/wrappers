import type { BaseLayoutProps } from 'fumadocs-ui/layouts/shared';

export const baseOptions: BaseLayoutProps = {
  nav: {
    title: 'Wrappers',
  },
  links: [
    {
      text: 'Catalog',
      url: '/docs/catalog',
    },
    {
      text: 'Guides',
      url: '/docs/guides',
    },
    {
      text: 'GitHub',
      url: 'https://github.com/supabase/wrappers',
      external: true,
    },
  ],
  githubUrl: 'https://github.com/supabase/wrappers',
};
