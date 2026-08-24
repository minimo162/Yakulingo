import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const app = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const pages = ['cat.html', 'quick.html'].map((name) => fs.readFileSync(path.join(app, 'www', name), 'utf8'));
const scripts = ['cat.js', 'premium-ui.js', 'quick-page.js'].map((name) => ({
  name,
  text: fs.readFileSync(path.join(app, 'www', 'assets', name), 'utf8')
}));
const declared = new Set();
const failures = [];

for (const text of pages) for (const match of text.matchAll(/\bid=["']([^"']+)["']/g)) declared.add(match[1]);
for (const { text } of scripts) {
  for (const match of text.matchAll(/\bid=\\?["']([^"']+)\\?["']/g)) declared.add(match[1]);
  for (const match of text.matchAll(/\.id\s*=\s*["']([^"']+)["']/g)) declared.add(match[1]);
}

for (const { name, text } of scripts) {
  const literalRefs = [
    ...text.matchAll(/\bel\(\s*["']([^"']+)["']\s*\)/g),
    ...text.matchAll(/getElementById\(\s*["']([^"']+)["']\s*\)/g),
    ...text.matchAll(/querySelector\(\s*["']#([A-Za-z][\w:-]*)["']\s*\)/g)
  ];
  for (const match of literalRefs) if (!declared.has(match[1])) failures.push(`${name}: missing #${match[1]}`);

  // Dynamic IDs hide drift from a static contract. Known variable lookups are
  // explicit by construction; new UI lookups must use exact literals.
  for (const match of text.matchAll(/\bel\(\s*([^)'"\s][^)]*)\)/g)) {
    const expression = match[1].trim();
    if (!['id', 'alignSideText[side]', 'proxyId', 'originalId', 'pair[0]', 'pair[1]'].includes(expression)) {
      failures.push(`${name}: dynamic ID lookup: ${expression}`);
    }
  }
}

if (failures.length) {
  failures.forEach((failure) => console.error(`not ok - ${failure}`));
  process.exit(1);
}
console.log(`ok - DOM ID contract (${declared.size} declared IDs)`);
