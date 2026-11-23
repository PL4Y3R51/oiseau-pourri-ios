#!/usr/bin/env node
// Generates Sources/OiseauCore/Generated/Models.swift from contract/openapi.json:
// one Codable struct per object schema, one tolerant enum per string enum.
//
// The Android app generates its models from the same file (openapi-generator);
// the schemas are flat enough (no oneOf/allOf) that a small generator gives plain,
// readable Swift without a runtime library. Admin-only shapes and multipart form
// bodies are left out, as on Android.
//
//   node tools/gen-models.mjs          write the file
//   node tools/gen-models.mjs --check  fail if the committed file is stale (CI)

import { readFileSync, writeFileSync, existsSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

const root = join(dirname(fileURLToPath(import.meta.url)), '..');
const spec = JSON.parse(readFileSync(join(root, 'contract/openapi.json'), 'utf8'));
const out = join(root, 'Sources/OiseauCore/Generated/Models.swift');

const KEYWORDS = new Set([
  'associatedtype', 'class', 'deinit', 'enum', 'extension', 'func', 'import', 'init', 'inout', 'internal',
  'let', 'operator', 'private', 'protocol', 'public', 'static', 'struct', 'subscript', 'typealias', 'var',
  'break', 'case', 'continue', 'default', 'defer', 'do', 'else', 'fallthrough', 'for', 'guard', 'if', 'in',
  'repeat', 'return', 'switch', 'where', 'while', 'as', 'catch', 'false', 'is', 'nil', 'rethrows', 'super',
  'self', 'Self', 'throw', 'throws', 'true', 'try', 'Type', 'Protocol',
]);
const ident = (n) => (KEYWORDS.has(n) ? `\`${n}\`` : n);
const upperFirst = (s) => s[0].toUpperCase() + s.slice(1);
const caseName = (v) => {
  const camel = v.replace(/[-_ ]+([a-zA-Z0-9])/g, (_, c) => c.toUpperCase());
  const n = /^[0-9]/.test(camel) ? `v${camel}` : camel[0].toLowerCase() + camel.slice(1);
  return ident(n);
};

const schemas = spec.components.schemas;
// ApiError: the error envelope, decoded by hand (ApiError.swift reads both servers' shapes).
const skipped = (name) => name.startsWith('Admin') || name.endsWith('Form') || name === 'ApiError';
const names = Object.keys(schemas).filter((n) => !skipped(n)).sort();

const nested = []; // inline enums, emitted after their owner

function swiftType(s, owner, prop) {
  if (s.$ref) {
    const ref = s.$ref.split('/').pop();
    if (skipped(ref)) throw new Error(`${owner}.${prop} refers to skipped schema ${ref}`);
    return ref;
  }
  // A boolean pinned to one value (`{ ok: true }`) is still a Bool to decode.
  if (s.enum && s.type !== 'string') return swiftType({ ...s, enum: undefined }, owner, prop);
  if (s.enum) {
    const name = `${owner}${upperFirst(prop)}`;
    nested.push(enumDecl(name, s.enum));
    return name;
  }
  switch (s.type) {
    case 'string':
      if (s.format === 'binary') return null;
      return 'String';
    case 'integer':
      return 'Int';
    case 'number':
      return 'Double';
    case 'boolean':
      return 'Bool';
    case 'array': {
      const t = swiftType(s.items, owner, prop);
      return t && `[${t}]`;
    }
    case 'object':
      if (s.additionalProperties && typeof s.additionalProperties === 'object' && !s.properties) {
        const t = swiftType(s.additionalProperties, owner, prop);
        return t && `[String: ${t}]`;
      }
      throw new Error(`${owner}.${prop}: inline object not supported, give it a schema name`);
    default:
      throw new Error(`${owner}.${prop}: unsupported schema ${JSON.stringify(s)}`);
  }
}

function enumDecl(name, values) {
  const cases = values.map((v) => `    case ${caseName(v)} = ${JSON.stringify(v)}`).join('\n');
  return `public enum ${name}: String, Codable, Hashable, Sendable, CaseIterable {
${cases}
    /// A value this build doesn't know yet: an older app keeps decoding a newer server.
    case unknown = "__unknown__"

    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = Self(rawValue: raw) ?? .unknown
    }
}`;
}

function structDecl(name, s) {
  if (s.type !== 'object') throw new Error(`${name}: not an object`);
  const required = new Set(s.required ?? []);
  const props = [];
  for (const [prop, ps] of Object.entries(s.properties ?? {})) {
    const t = swiftType(ps, name, prop);
    if (!t) continue; // a file part of a form
    const optional = ps.nullable || !required.has(prop);
    props.push({ prop, type: optional ? `${t}?` : t, optional });
  }
  const fields = props.map((p) => `    public var ${ident(p.prop)}: ${p.type}`).join('\n');
  const params = props.map((p) => `${ident(p.prop)}: ${p.type}${p.optional ? ' = nil' : ''}`).join(', ');
  const assigns = props.map((p) => `        self.${p.prop} = ${ident(p.prop)}`).join('\n');
  return `public struct ${name}: Codable, Hashable, Sendable {
${fields}

    public init(${params}) {
${assigns}
    }
}`;
}

const decls = [];
for (const name of names) {
  const s = schemas[name];
  if (s.enum) decls.push(enumDecl(name, s.enum));
  else {
    decls.push(structDecl(name, s));
    decls.push(...nested.splice(0));
  }
}

const text = `// Generated by tools/gen-models.mjs from contract/openapi.json. Do not edit.
// Re-run \`node tools/gen-models.mjs\` after \`node tools/sync-from-monorepo.mjs\`.

import Foundation

${decls.join('\n\n')}
`;

if (process.argv.includes('--check')) {
  const current = existsSync(out) ? readFileSync(out, 'utf8') : '';
  if (current !== text) {
    console.error('Models.swift is stale: run `node tools/gen-models.mjs` and commit the result.');
    process.exit(1);
  }
  console.log('Models.swift is up to date.');
} else {
  writeFileSync(out, text);
  console.log(`Models.swift: ${decls.length} declarations`);
}
