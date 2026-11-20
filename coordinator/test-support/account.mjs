import { readFileSync, readdirSync } from "node:fs";
import { DatabaseSync } from "node:sqlite";

const coordinator = new URL("../", import.meta.url);
const changes = (number) => ({ success: true, meta: { changes: Number(number) } });

export function openAccountDatabase(path = ":memory:", { migrate = true } = {}) {
  const database = new DatabaseSync(path);
  database.exec("PRAGMA foreign_keys = ON");
  if (migrate) {
    const migrations = readdirSync(coordinator).filter((name) => /^account.*\.sql$/.test(name)).sort();
    if (migrations.length === 0) throw new Error("No account migrations found");
    for (const name of migrations) database.exec(readFileSync(new URL(name, coordinator), "utf8"));
  }

  function statement(sql, params = []) {
    const query = database.prepare(sql);
    const run = () => query.columns().length
      ? { success: true, results: query.all(...params), meta: { changes: Number(database.prepare("SELECT changes() AS count").get().count) } }
      : { ...changes(query.run(...params).changes), results: [] };
    return {
      bind: (...values) => statement(sql, values),
      execute: run,
      run: async () => run(),
      all: async () => ({ success: true, results: query.all(...params) }),
      first: async (column) => {
        const row = query.get(...params);
        if (!row) return null;
        return column === undefined ? row : row[column];
      },
      raw: async () => query.all(...params).map(Object.values),
    };
  }

  return {
    close: () => database.close(),
    prepare: statement,
    exec: async (sql) => database.exec(sql),
    batch: async (statements) => {
      database.exec("BEGIN");
      try {
        const results = statements.map((item) => item.execute());
        database.exec("COMMIT");
        return results;
      } catch (error) {
        database.exec("ROLLBACK");
        throw error;
      }
    },
  };
}

export function memoryRecordingBucket() {
  const objects = new Map();
  return {
    objects,
    async put(key, data, options = {}) {
      const bytes = new Uint8Array(await new Response(data).arrayBuffer());
      const object = { key, bytes, size: bytes.length, httpMetadata: options.httpMetadata, customMetadata: options.customMetadata };
      objects.set(key, object);
      return object;
    },
    async get(key) {
      const object = objects.get(key);
      if (!object) return null;
      return {
        ...object,
        body: new Response(object.bytes).body,
        arrayBuffer: async () => object.bytes.slice().buffer,
        text: async () => new TextDecoder().decode(object.bytes),
      };
    },
    async head(key) {
      return objects.get(key) ?? null;
    },
    async delete(keys) {
      for (const key of [keys].flat()) objects.delete(key);
    },
    async list({ prefix = "" } = {}) {
      return { objects: [...objects.values()].filter(({ key }) => key.startsWith(prefix)), truncated: false };
    },
  };
}
