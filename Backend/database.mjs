import pg from "pg";

const { Pool } = pg;

export function createDatabase(databaseURL) {
  const pool = new Pool({ connectionString: databaseURL, max: 12, ssl: databaseURL.includes("localhost") || databaseURL.includes("127.0.0.1") ? false : { rejectUnauthorized: false } });
  return {
    query: (text, values) => pool.query(text, values),
    async transaction(operation) {
      const client = await pool.connect();
      try { await client.query("begin"); const result = await operation(client); await client.query("commit"); return result; }
      catch (error) { await client.query("rollback"); throw error; }
      finally { client.release(); }
    },
    close: () => pool.end()
  };
}
