// Test doubles: a D1-compatible wrapper over node:sqlite and an in-memory R2.
import { DatabaseSync } from "node:sqlite";
import { readFileSync } from "node:fs";

export function fakeD1() {
  const db = new DatabaseSync(":memory:");
  db.exec(readFileSync(new URL("../migrations/0001_licenses.sql", import.meta.url), "utf8"));
  return {
    raw: db,
    prepare(sql) {
      let params = [];
      const statement = {
        bind(...values) {
          params = values;
          return statement;
        },
        async first() {
          return db.prepare(sql).get(...params) ?? null;
        },
        async all() {
          return { results: db.prepare(sql).all(...params) };
        },
        async run() {
          const info = db.prepare(sql).run(...params);
          return { success: true, meta: { changes: Number(info.changes) } };
        },
      };
      return statement;
    },
  };
}

export function fakeR2(files = {}) {
  const store = new Map(Object.entries(files).map(([k, v]) => [k, new TextEncoder().encode(v)]));
  const make = (key, bytes, range) => {
    let body = bytes;
    let r;
    if (range) {
      r = range;
      const offset = range.offset ?? 0;
      body = bytes.slice(offset, offset + (range.length ?? bytes.length - offset));
    }
    return {
      key,
      size: bytes.length,
      httpEtag: `"etag-${key}"`,
      range: r,
      body: new Blob([body]).stream(),
      text: async () => new TextDecoder().decode(bytes),
      writeHttpMetadata() {},
    };
  };
  return {
    store,
    async get(key, options = {}) {
      const bytes = store.get(key);
      if (!bytes) return null;
      const header = options.range?.get?.("range");
      const match = header && /^bytes=(\d+)-(\d+)$/.exec(header);
      return make(key, bytes, match ? { offset: +match[1], length: +match[2] - +match[1] + 1 } : undefined);
    },
    async head(key) {
      const bytes = store.get(key);
      if (!bytes) return null;
      const object = make(key, bytes);
      delete object.body;
      return object;
    },
  };
}
