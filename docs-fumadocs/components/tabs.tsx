'use client';

import * as React from 'react';
import * as TabsPrimitive from '@radix-ui/react-tabs';
import { cn } from '@/lib/utils';

interface TabsProps {
  items: string[];
  children: React.ReactNode;
  defaultValue?: string;
  className?: string;
}

export function Tabs({ items, children, defaultValue, className }: TabsProps) {
  const defaultTab = defaultValue || items[0];

  return (
    <TabsPrimitive.Root
      defaultValue={defaultTab}
      className={cn('my-4 overflow-hidden rounded-lg border bg-fd-card', className)}
    >
      <TabsPrimitive.List className="flex flex-row items-end gap-4 overflow-x-auto bg-fd-secondary px-4 text-fd-muted-foreground">
        {items.map((item) => (
          <TabsPrimitive.Trigger
            key={item}
            value={item}
            className="whitespace-nowrap border-b-2 border-transparent py-2 text-sm font-medium transition-colors hover:text-fd-accent-foreground data-[state=active]:border-fd-primary data-[state=active]:text-fd-primary"
          >
            {item}
          </TabsPrimitive.Trigger>
        ))}
      </TabsPrimitive.List>
      {children}
    </TabsPrimitive.Root>
  );
}

interface TabProps {
  value: string;
  children: React.ReactNode;
  className?: string;
}

export function Tab({ value, children, className }: TabProps) {
  return (
    <TabsPrimitive.Content
      value={value}
      className={cn('p-4', className)}
    >
      {children}
    </TabsPrimitive.Content>
  );
}
