#!/usr/bin/env node
// The one bridge to the oiseau-pourri monorepo, run by hand. It reads a commit of
// the monorepo (origin/main by default, never the working tree) and refreshes:
//
//  - contract/openapi.json              the API contract (models are generated from it)
//  - Tests/OiseauCoreTests/Fixtures/contract/*.json
//                                       real API answers recorded by the API's test suite
//  - App/Resources/Localizable.xcstrings
//                                       the Android strings, same keys, same French
//  - App/Resources/Assets.xcassets      Lucide icons (SVG), mascot poses (PNG), app icon
//  - App/Resources/Fonts/Syne.ttf       the one font of the Zine look
//  - contract/SOURCE                    which monorepo commit all this came from
//
// then regenerates the Swift models.
//
//   node tools/sync-from-monorepo.mjs [--repo D:/dev/oiseau-pourri] [--ref origin/main]
//
// Needs the monorepo's node_modules (for sharp, from `pnpm install` there).

import { execFileSync } from 'node:child_process';
import { createRequire } from 'node:module';
import { mkdirSync, rmSync, writeFileSync, readdirSync } from 'node:fs';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const root = join(dirname(fileURLToPath(import.meta.url)), '..');
const arg = (name, fallback) => {
  const i = process.argv.indexOf(name);
  return i > 0 ? process.argv[i + 1] : fallback;
};
const repo = resolve(arg('--repo', join(root, '../oiseau-pourri')));
const ref = arg('--ref', 'origin/main');

const git = (...args) => execFileSync('git', ['-C', repo, ...args], { maxBuffer: 64 << 20 });
const show = (path) => git('show', `${ref}:${path}`);
const list = (path) =>
  git('ls-tree', '--name-only', `${ref}:${path}`).toString().split('\n').filter(Boolean);

const sharp = createRequire(join(repo, 'apps/api/package.json'))('sharp');

const ANDROID_RES = 'apps/android/app/src/main/res';
const json = (o) => JSON.stringify(o, null, 2) + '\n';

// --- contract -------------------------------------------------------------------

function syncContract() {
  writeFileSync(join(root, 'contract/openapi.json'), show('apps/api/openapi.json'));
  const dir = join(root, 'Tests/OiseauCoreTests/Fixtures/contract');
  rmSync(dir, { recursive: true, force: true });
  mkdirSync(dir, { recursive: true });
  const src = 'apps/android/app/src/test/resources/contract';
  const files = list(src).filter((f) => f.endsWith('.json'));
  for (const f of files) writeFileSync(join(dir, f), show(`${src}/${f}`));
  console.log(`contract: openapi.json + ${files.length} fixtures`);
}

// --- strings --------------------------------------------------------------------

const ENTITIES = { amp: '&', lt: '<', gt: '>', quot: '"', apos: "'" };

/** Android resource text → the plain string, then Android format specifiers → Apple's. */
function convert(raw) {
  let s = raw.trim();
  const cdata = s.match(/^<!\[CDATA\[([\s\S]*)\]\]>$/);
  if (cdata) s = cdata[1];
  if (/^".*"$/s.test(s)) s = s.slice(1, -1);
  s = s
    .replace(/&#x([0-9a-f]+);/gi, (_, h) => String.fromCodePoint(parseInt(h, 16)))
    .replace(/&#([0-9]+);/g, (_, d) => String.fromCodePoint(Number(d)))
    .replace(/&(amp|lt|gt|quot|apos);/g, (_, e) => ENTITIES[e])
    .replace(/\\u([0-9a-fA-F]{4})/g, (_, h) => String.fromCharCode(parseInt(h, 16)))
    .replace(/\\n/g, '\n')
    .replace(/\\t/g, '\t')
    .replace(/\\(['"@?\\])/g, '$1');
  if (/<[a-z]/i.test(s)) throw new Error(`markup in a string is not supported yet: ${raw}`);
  return s
    .replace(/%(\d+\$)?s/g, (_, p) => `%${p ?? ''}@`)
    .replace(/%(\d+\$)?d/g, (_, p) => `%${p ?? ''}ld`);
}

const unit = (value) => ({ stringUnit: { state: 'translated', value } });

function syncStrings() {
  const xml = show(`${ANDROID_RES}/values/strings.xml`).toString().replace(/<!--[\s\S]*?-->/g, '');
  const strings = {};
  for (const m of xml.matchAll(/<string\s+name="([^"]+)"[^>]*>([\s\S]*?)<\/string>/g)) {
    strings[m[1]] = { localizations: { fr: unit(convert(m[2])) } };
  }
  for (const m of xml.matchAll(/<plurals\s+name="([^"]+)"[^>]*>([\s\S]*?)<\/plurals>/g)) {
    const plural = {};
    for (const it of m[2].matchAll(/<item\s+quantity="([a-z]+)"\s*>([\s\S]*?)<\/item>/g)) plural[it[1]] = unit(convert(it[2]));
    strings[m[1]] = { localizations: { fr: { variations: { plural } } } };
  }
  for (const m of xml.matchAll(/<string-array\s+name="([^"]+)"[^>]*>([\s\S]*?)<\/string-array>/g)) {
    [...m[2].matchAll(/<item\s*>([\s\S]*?)<\/item>/g)].forEach((it, i) => {
      strings[`${m[1]}.${i}`] = { localizations: { fr: unit(convert(it[1])) } };
    });
  }
  const sorted = Object.fromEntries(Object.keys(strings).sort().map((k) => [k, { extractionState: 'manual', ...strings[k] }]));
  writeFileSync(join(root, 'App/Resources/Localizable.xcstrings'), json({ sourceLanguage: 'fr', strings: sorted, version: '1.0' }));
  console.log(`strings: ${Object.keys(sorted).length} keys`);
}

// --- assets ---------------------------------------------------------------------

const catalog = join(root, 'App/Resources/Assets.xcassets');
const info = { author: 'xcode', version: 1 };

function imageset(name, file, data, properties) {
  const dir = join(catalog, `${name}.imageset`);
  mkdirSync(dir, { recursive: true });
  writeFileSync(join(dir, file), data);
  const images = file.endsWith('.svg') ? [{ filename: file, idiom: 'universal' }] : [{ filename: file, idiom: 'universal', scale: '1x' }];
  writeFileSync(join(dir, 'Contents.json'), json({ images, info, ...(properties ? { properties } : {}) }));
}

/** The Android vector drawables are Lucide's strokes as paths: rewrap them as SVG. */
function vectorToSvg(xml) {
  const paths = [...xml.matchAll(/android:pathData="([^"]+)"/g)].map((m) => `<path d="${m[1]}"/>`);
  return (
    '<svg xmlns="http://www.w3.org/2000/svg" width="24" height="24" viewBox="0 0 24 24" fill="none" ' +
    'stroke="#000000" stroke-width="2" stroke-linecap="round" stroke-linejoin="round">' +
    paths.join('') +
    '</svg>\n'
  );
}

async function syncAssets() {
  for (const d of readdirSync(catalog, { withFileTypes: true })) {
    if (d.isDirectory() && /^(lucide_|mascotte_)/.test(d.name)) rmSync(join(catalog, d.name), { recursive: true });
  }
  writeFileSync(join(catalog, 'Contents.json'), json({ info }));

  const icons = list(`${ANDROID_RES}/drawable`).filter((f) => /^lucide_.*\.xml$/.test(f));
  for (const f of icons) {
    const name = f.replace(/\.xml$/, '');
    imageset(name, `${name}.svg`, vectorToSvg(show(`${ANDROID_RES}/drawable/${f}`).toString()), {
      'preserves-vector-representation': true,
      'template-rendering-intent': 'template',
    });
  }

  const poses = list(`${ANDROID_RES}/drawable-nodpi`).filter((f) => /^mascotte_.*\.webp$/.test(f));
  for (const f of poses) {
    const name = f.replace(/\.webp$/, '');
    imageset(name, `${name}.png`, await sharp(show(`${ANDROID_RES}/drawable-nodpi/${f}`)).png().toBuffer());
  }

  // App icon: one 1024 px image, opaque (the App Store refuses alpha), on the Zine paper.
  const iconDir = join(catalog, 'AppIcon.appiconset');
  mkdirSync(iconDir, { recursive: true });
  const icon = await sharp(show('apps/web/public/icon-512.png'))
    .resize(1024, 1024, { kernel: 'lanczos3' })
    .flatten({ background: '#F7F6F1' })
    .png()
    .toBuffer();
  writeFileSync(join(iconDir, 'icon-1024.png'), icon);
  writeFileSync(
    join(iconDir, 'Contents.json'),
    json({ images: [{ filename: 'icon-1024.png', idiom: 'universal', platform: 'ios', size: '1024x1024' }], info }),
  );

  mkdirSync(join(root, 'App/Resources/Fonts'), { recursive: true });
  writeFileSync(join(root, 'App/Resources/Fonts/Syne.ttf'), show(`${ANDROID_RES}/font/syne.ttf`));
  console.log(`assets: ${icons.length} icons, ${poses.length} mascot poses, app icon, Syne`);
}

// --------------------------------------------------------------------------------

syncContract();
syncStrings();
await syncAssets();
const sha = git('rev-parse', ref).toString().trim();
const date = git('show', '-s', '--format=%cI', ref).toString().trim();
writeFileSync(join(root, 'contract/SOURCE'), `${sha} ${date}\n`);
execFileSync(process.execPath, [join(root, 'tools/gen-models.mjs')], { stdio: 'inherit' });
console.log(`synced from ${ref} = ${sha.slice(0, 10)}`);
