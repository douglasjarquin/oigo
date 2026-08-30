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
  }

  const designSystem = read('design-system/index.html');
  if (designSystem !== null) {
    if (!hasRobotsNoindex(designSystem)) {
      fail('design-system/index.html must include robots noindex');
    }
  }

  const notFound = read('404.html');
  if (notFound !== null) {
    if (!hasRobotsNoindex(notFound)) {
      fail('404.html must include robots noindex');
    }
  }
}

if (failures.length > 0) {
  for (const message of failures) {
    console.error(`FAIL: ${message}`);
  }
  process.exit(1);
}

console.log('GREEN: site SEO smoke passed');
