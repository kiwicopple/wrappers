#!/usr/bin/env node

const fs = require('fs');
const path = require('path');

const DOCS_DIR = path.join(__dirname, '..', 'docs');
const OUTPUT_DIR = path.join(__dirname, '..', 'docs-fumadocs', 'content', 'docs');

// Type mapping for admonitions
const ADMONITION_MAP = {
  note: 'info',
  info: 'info',
  tip: 'info',
  warning: 'warn',
  caution: 'warn',
  danger: 'error',
  error: 'error',
};

function convertAdmonitions(content) {
  // Match admonitions with title: !!! type "Title"
  const admonitionWithTitleRegex = /^(!{3})\s+(note|info|tip|warning|caution|danger|error)\s+"([^"]+)"\s*\n((?:(?:    |\t).*\n?)*)/gm;

  content = content.replace(admonitionWithTitleRegex, (match, bangs, type, title, body) => {
    const fdType = ADMONITION_MAP[type.toLowerCase()] || 'info';
    const cleanBody = body.replace(/^(    |\t)/gm, '').trim();
    return `<Callout type="${fdType}" title="${title}">\n${cleanBody}\n</Callout>\n`;
  });

  // Match admonitions without title: !!! type
  const admonitionNoTitleRegex = /^(!{3})\s+(note|info|tip|warning|caution|danger|error)\s*\n((?:(?:    |\t).*\n?)*)/gm;

  content = content.replace(admonitionNoTitleRegex, (match, bangs, type, body) => {
    const fdType = ADMONITION_MAP[type.toLowerCase()] || 'info';
    const cleanBody = body.replace(/^(    |\t)/gm, '').trim();
    return `<Callout type="${fdType}">\n${cleanBody}\n</Callout>\n`;
  });

  return content;
}

function convertTabs(content) {
  // Find consecutive tab blocks (=== "Title" followed by indented content)
  // A tab group ends when we hit a non-indented line that isn't another ===
  const lines = content.split('\n');
  const result = [];
  let i = 0;

  while (i < lines.length) {
    const line = lines[i];
    const tabMatch = line.match(/^===\s+"([^"]+)"\s*$/);

    if (tabMatch) {
      // Start of a tab group - collect all consecutive tabs
      const tabs = [];

      while (i < lines.length) {
        const currentLine = lines[i];
        const currentTabMatch = currentLine.match(/^===\s+"([^"]+)"\s*$/);

        if (currentTabMatch) {
          const tabTitle = currentTabMatch[1];
          const tabContent = [];
          i++;

          // Skip empty line after tab header
          if (i < lines.length && lines[i].trim() === '') {
            i++;
          }

          // Collect indented content (4 spaces or tab)
          while (i < lines.length) {
            const contentLine = lines[i];
            // Check if this is the start of a new tab
            if (contentLine.match(/^===\s+"[^"]+"\s*$/)) {
              break;
            }
            // Check if this is non-indented, non-empty content (end of tab group)
            if (contentLine.trim() !== '' && !contentLine.match(/^(    |\t)/)) {
              break;
            }
            // Add the line (removing 4-space or tab indent)
            tabContent.push(contentLine.replace(/^(    |\t)/, ''));
            i++;
          }

          // Trim trailing empty lines from tab content
          while (tabContent.length > 0 && tabContent[tabContent.length - 1].trim() === '') {
            tabContent.pop();
          }

          tabs.push({ title: tabTitle, content: tabContent.join('\n') });
        } else {
          // Not a tab header, end of tab group
          break;
        }
      }

      // Generate Tabs component
      if (tabs.length > 0) {
        const items = tabs.map(t => `'${t.title}'`).join(', ');
        const tabElements = tabs.map(t => {
          const indentedContent = t.content.split('\n').map(l => '    ' + l).join('\n');
          return `  <Tab value="${t.title}">\n${indentedContent}\n  </Tab>`;
        }).join('\n');
        result.push(`<Tabs items={[${items}]}>\n${tabElements}\n</Tabs>`);
      }
    } else {
      result.push(line);
      i++;
    }
  }

  return result.join('\n');
}

function convertLinks(content) {
  // Convert .md links to route paths
  content = content.replace(/\]\(([^)]+)\.md(#[^)]+)?\)/g, ']($1$2)');
  // Convert relative paths
  content = content.replace(/\]\(\.\.\/([^)]+)\)/g, ']($1)');
  return content;
}

function fixImagePaths(content) {
  // Fix image paths to use absolute paths from public folder
  content = content.replace(/!\[([^\]]*)\]\(assets\//g, '![$1](/assets/');
  content = content.replace(/src="assets\//g, 'src="/assets/');
  content = content.replace(/src='assets\//g, "src='/assets/");
  return content;
}

function fixHtmlTags(content) {
  // Make void HTML elements self-closing for JSX/MDX compatibility
  // Fix <img ...> to <img ... />
  content = content.replace(/<img([^>]*[^/])>/gi, '<img$1 />');
  // Fix <br> to <br />
  content = content.replace(/<br\s*>/gi, '<br />');
  // Fix <hr> to <hr />
  content = content.replace(/<hr\s*>/gi, '<hr />');
  // Fix <input ...> to <input ... />
  content = content.replace(/<input([^>]*[^/])>/gi, '<input$1 />');
  return content;
}

function escapeJsxIssues(content) {
  // Escape backslashes in inline code that might cause issues
  // This is tricky - we need to be careful not to break code blocks

  // Fix escaped quotes in attribute values (common issue)
  // e.g., title=\"something\" should be title="something"
  content = content.replace(/(\w+)=\\"([^"\\]*(?:\\.[^"\\]*)*)\\"/g, '$1="$2"');

  // Fix escaped angle brackets like <objectType\> -> `<objectType>`
  // These are often used in tables to show placeholder values
  content = content.replace(/<([a-zA-Z_]+)\\>/g, '`<$1>`');

  // Fix remaining backslash-escaped angle brackets
  content = content.replace(/\\>/g, '>');
  content = content.replace(/\\</g, '<');

  // Fix angle brackets in table cells (| <something> | -> | `<something>` |)
  // These look like JSX tags but are just text placeholders
  content = content.replace(/\|\s*<([a-zA-Z_][a-zA-Z0-9_]*)>\s*\|/g, '| `<$1>` |');

  return content;
}

function extractAndConvertFrontMatter(content, filePath) {
  const fmRegex = /^---\n([\s\S]*?)\n---\n/;
  const match = content.match(fmRegex);

  // Extract title from first h1 heading
  const h1Match = content.match(/^#\s+(.+)$/m);
  const title = h1Match ? h1Match[1] : path.basename(filePath, '.md');

  // Extract description from first paragraph after h1
  const descMatch = content.match(/^#\s+.+\n+([^#\n][^\n]+)/m);
  const description = descMatch ? descMatch[1].substring(0, 160) : '';

  const newFrontMatter = `---
title: "${title.replace(/"/g, '\\"')}"
description: "${description.replace(/"/g, '\\"')}"
---`;

  if (match) {
    return content.replace(fmRegex, newFrontMatter + '\n');
  }
  return newFrontMatter + '\n\n' + content;
}

function convertFile(inputPath, outputPath) {
  let content = fs.readFileSync(inputPath, 'utf-8');

  // Convert front matter
  content = extractAndConvertFrontMatter(content, inputPath);

  // Convert admonitions
  content = convertAdmonitions(content);

  // Convert tabs
  content = convertTabs(content);

  // Convert links
  content = convertLinks(content);

  // Fix image paths
  content = fixImagePaths(content);

  // Fix HTML tags for JSX compatibility
  content = fixHtmlTags(content);

  // Escape JSX issues
  content = escapeJsxIssues(content);

  // Ensure output directory exists
  const outputDir = path.dirname(outputPath);
  fs.mkdirSync(outputDir, { recursive: true });

  // Write output file
  fs.writeFileSync(outputPath, content);
  console.log(`Converted: ${inputPath} -> ${outputPath}`);
}

function walkDir(dir, callback, baseDir = dir) {
  const files = fs.readdirSync(dir);
  files.forEach(file => {
    const filePath = path.join(dir, file);
    const stat = fs.statSync(filePath);
    if (stat.isDirectory()) {
      // Skip certain directories
      if (!['stylesheets', 'assets'].includes(file)) {
        walkDir(filePath, callback, baseDir);
      }
    } else if (file.endsWith('.md') && file !== 'tags.md') {
      callback(filePath, baseDir);
    }
  });
}

function main() {
  console.log('Starting migration...\n');

  // Convert all markdown files
  walkDir(DOCS_DIR, (filePath, baseDir) => {
    const relativePath = path.relative(baseDir, filePath);
    const outputPath = path.join(OUTPUT_DIR, relativePath.replace('.md', '.mdx'));
    convertFile(filePath, outputPath);
  });

  console.log('\nMigration complete!');
}

main();
