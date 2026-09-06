import { readFileSync, existsSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

const siteRoot = join(dirname(fileURLToPath(import.meta.url)), '..');
const dist = join(siteRoot, 'dist');
const liveOrigin = 'https://douglasjarquin.github.io';
const canonicalHome = `${liveOrigin}/oigo/`;
const sitemapUrl = `${liveOrigin}/oigo/sitemap.xml`;
const failures = [];

function fail(message) {
  failures.push(message);
}

function read(relativePath) {
  const path = join(dist, relativePath);
  if (!existsSync(path)) {
    fail(`missing ${relativePath}`);
    return null;
  }
  return readFileSync(path, 'utf8');
}

function hasRobotsNoindex(html) {
  return /<meta\s+name="robots"\s+content="noindex(?:\s*,\s*nofollow)?"\s*\/?>/i.test(html)
    || /<meta\s+content="noindex(?:\s*,\s*nofollow)?"\s+name="robots"\s*\/?>/i.test(html);
}

function canonicalHref(html) {
  const relFirst = html.match(/<link\s+rel="canonical"\s+href="([^"]+)"\s*\/?>/i);
  if (relFirst) {
    return relFirst[1];
  }
  const hrefFirst = html.match(/<link\s+href="([^"]+)"\s+rel="canonical"\s*\/?>/i);
  return hrefFirst ? hrefFirst[1] : null;
}

function decodeHtml(text) {
  return text
    .replaceAll('&amp;', '&')
    .replaceAll('&lt;', '<')
    .replaceAll('&gt;', '>')
    .replaceAll('&quot;', '"')
    .replaceAll('&#39;', "'")
    .replaceAll('&apos;', "'");
}

function jsonLdDocuments(html) {
  const documents = [];
  const scriptPattern = /<script\b[^>]*\btype="application\/ld\+json"[^>]*>([\s\S]*?)<\/script>/gi;
  for (const match of html.matchAll(scriptPattern)) {
    try {
      documents.push(JSON.parse(match[1]));
    } catch {
      fail('JSON-LD is not valid JSON');
    }
  }
  return documents;
}

function jsonLdNodes(documents) {
  const nodes = [];
  for (const document of documents) {
    if (Array.isArray(document['@graph'])) {
      nodes.push(...document['@graph']);
    } else {
      nodes.push(document);
    }
  }
  return nodes;
}

function nodeTypes(node) {
  const type = node['@type'];
  if (Array.isArray(type)) {
    return type;
  }
  return typeof type === 'string' ? [type] : [];
}

function findNodeByType(nodes, type) {
  return nodes.find((node) => nodeTypes(node).includes(type)) ?? null;
}

function visibleFaq(html) {
  return [...html.matchAll(/<summary\b[^>]*>([\s\S]*?)<\/summary>\s*<p\b[^>]*\bclass="faq-answer"[^>]*>([\s\S]*?)<\/p>/g)].map((match) => ({
    question: decodeHtml(match[1].trim()),
    answer: decodeHtml(match[2].trim()),
  }));
}

function assertNoFaqPage(html, label) {
  const nodes = jsonLdNodes(jsonLdDocuments(html));
  if (findNodeByType(nodes, 'FAQPage')) {
    fail(`${label} must not include FAQPage JSON-LD`);
  }
}

function assertHomeFaqPage(html) {
  const nodes = jsonLdNodes(jsonLdDocuments(html));
  if (!findNodeByType(nodes, 'WebSite')) {
    fail('index.html must keep WebSite JSON-LD');
  }
  if (!findNodeByType(nodes, 'Organization')) {
    fail('index.html must keep Organization JSON-LD');
  }
  const faqPage = findNodeByType(nodes, 'FAQPage');
  if (!faqPage) {
    fail('index.html must include FAQPage JSON-LD');
    return;
  }
  const entities = Array.isArray(faqPage.mainEntity) ? faqPage.mainEntity : [];
  const visible = visibleFaq(html);
  if (visible.length === 0) {
    fail('index.html is missing visible FAQ entries to compare with FAQPage');
    return;
  }
  if (entities.length !== visible.length) {
    fail(`FAQPage mainEntity count is ${entities.length}, expected ${visible.length}`);
  }
  const count = Math.min(entities.length, visible.length);
  for (let index = 0; index < count; index += 1) {
    const entity = entities[index];
    const expected = visible[index];
    if (!nodeTypes(entity).includes('Question')) {
      fail(`FAQPage mainEntity[${index}] must be a Question`);
    }
    if (entity.name !== expected.question) {
      fail(`FAQPage Question name mismatch at ${index}`);
    }
    const acceptedAnswer = entity.acceptedAnswer;
    if (!acceptedAnswer || !nodeTypes(acceptedAnswer).includes('Answer')) {
      fail(`FAQPage mainEntity[${index}] must have an acceptedAnswer Answer`);
      continue;
    }
    if (acceptedAnswer.text !== expected.answer) {
      fail(`FAQPage acceptedAnswer text mismatch at ${index}`);
    }
  }
}

if (!existsSync(dist)) {
  fail('site/dist is missing; run npm run build first');
} else {
  const robots = read('robots.txt');
  if (robots !== null) {
    if (/<html/i.test(robots)) {
      fail('robots.txt is HTML, not a robots file');
    }
    if (!/^\s*User-agent:\s*\*/im.test(robots)) {
      fail('robots.txt must allow a User-agent');
    }
    if (/^\s*Disallow:\s*\/\s*$/im.test(robots) && !/^\s*Allow:\s*\//im.test(robots)) {
      fail('robots.txt blocks crawlers');
    }
    if (!/^\s*Allow:\s*\//im.test(robots) && !/^\s*Disallow:\s*$/im.test(robots)) {
      fail('robots.txt must allow crawlers');
    }
    const sitemapLine = robots.match(/^\s*Sitemap:\s*(\S+)\s*$/im);
    if (!sitemapLine) {
      fail('robots.txt is missing a Sitemap line');
    } else if (sitemapLine[1] !== sitemapUrl) {
      fail(`robots.txt Sitemap is ${sitemapLine[1]}, expected ${sitemapUrl}`);
    }
  }

  const sitemap = read('sitemap.xml');
  if (sitemap !== null) {
    if (/<html/i.test(sitemap)) {
      fail('sitemap.xml is HTML, not XML');
    }
    const locs = [...sitemap.matchAll(/<loc>\s*([^<]+?)\s*<\/loc>/gi)].map((match) => match[1].trim());
    if (!locs.includes(canonicalHome)) {
      fail(`sitemap.xml missing canonical ${canonicalHome}`);
    }
    const extras = locs.filter((loc) => loc !== canonicalHome);
    if (extras.length > 0) {
      fail(`sitemap.xml has unexpected URLs: ${extras.join(', ')}`);
    }
    if (/design-system/i.test(sitemap)) {
      fail('sitemap.xml must omit /oigo/design-system/');
    }
    if (/404/i.test(sitemap)) {
      fail('sitemap.xml must omit the 404 page');
    }
  }

  const home = read('index.html');
  if (home !== null) {
    const href = canonicalHref(home);
    if (href !== canonicalHome) {
      fail(`index.html canonical is ${href ?? '(missing)'}, expected ${canonicalHome}`);
    }
    if (hasRobotsNoindex(home)) {
      fail('index.html must stay indexable');
    }
    assertHomeFaqPage(home);
  }

  const designSystem = read('design-system/index.html');
  if (designSystem !== null) {
    if (!hasRobotsNoindex(designSystem)) {
      fail('design-system/index.html must include robots noindex');
    }
    assertNoFaqPage(designSystem, 'design-system/index.html');
  }

  const notFound = read('404.html');
  if (notFound !== null) {
    if (!hasRobotsNoindex(notFound)) {
      fail('404.html must include robots noindex');
    }
    assertNoFaqPage(notFound, '404.html');
  }
}

if (failures.length > 0) {
  for (const message of failures) {
    console.error(`FAIL: ${message}`);
  }
  process.exit(1);
}

console.log('GREEN: site SEO smoke passed');
