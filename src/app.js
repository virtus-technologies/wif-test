const express = require("express");
const axios = require("axios");
const { readFile } = require("./gcs");

const app = express();
app.use(express.json());

// ─── Logger ──────────────────────────────────────────────────────────────────
function log(level, message, extra = {}) {
  const entry = {
    timestamp: new Date().toISOString(),
    level,
    message,
    ...extra,
  };
  const fn = level === "ERROR" ? console.error : console.log;
  fn(JSON.stringify(entry));
}

// ─── Request/response middleware ─────────────────────────────────────────────
app.use((req, res, next) => {
  const start = Date.now();
  log("INFO", "Incoming request", { method: req.method, path: req.path, query: req.query });

  res.on("finish", () => {
    const ms = Date.now() - start;
    const level = res.statusCode >= 500 ? "ERROR" : res.statusCode >= 400 ? "WARN" : "INFO";
    log(level, "Request completed", {
      method: req.method,
      path: req.path,
      status: res.statusCode,
      durationMs: ms,
    });
  });

  next();
});

// ─── Routes ──────────────────────────────────────────────────────────────────
app.get("/", (_req, res) => {
  res.json({
    app: "wif-test",
    description: "Node.js + Express demo deployed via OIDC / Workload Identity Federation",
    routes: [
      { method: "GET", path: "/health",                              description: "Health check" },
      { method: "GET", path: "/currency?from=USD&to=EUR&amount=100", description: "Currency conversion" },
      { method: "GET", path: "/files/read?file=ping.txt",            description: "Read file from GCS via WIF" },
    ],
  });
});

app.get("/health", (_req, res) => {
  res.json({ status: "ok", timestamp: new Date().toISOString() });
});

/**
 * GET /currency?from=USD&to=EUR&amount=100
 *
 * Uses the free Open Exchange Rates API (no key required for latest rates
 * relative to USD). Converts any amount between two currencies.
 */
app.get("/currency", async (req, res) => {
  const from   = (req.query.from   || "USD").toUpperCase();
  const to     = (req.query.to     || "EUR").toUpperCase();
  const amount = parseFloat(req.query.amount || "1");

  if (isNaN(amount) || amount <= 0) {
    log("WARN", "Invalid amount parameter", { amount: req.query.amount });
    return res.status(400).json({ error: "amount must be a positive number" });
  }

  const url = `https://open.er-api.com/v6/latest/${from}`;
  log("INFO", "Fetching exchange rates", { url, from, to, amount });
  const t0 = Date.now();

  try {
    const { data } = await axios.get(url, { timeout: 8000 });
    log("INFO", "Exchange rate API responded", { durationMs: Date.now() - t0, result: data.result });

    if (data.result !== "success") {
      log("ERROR", "Exchange rate API returned non-success result", { detail: data });
      return res.status(502).json({ error: "Exchange rate API returned an error", detail: data });
    }

    const rate = data.rates[to];
    if (rate === undefined) {
      log("WARN", "Unknown target currency", { to });
      return res.status(404).json({ error: `Unknown currency code: ${to}` });
    }

    const converted = parseFloat((amount * rate).toFixed(6));
    log("INFO", "Currency conversion successful", { from, to, amount, rate, converted });

    res.json({
      from,
      to,
      amount,
      rate,
      converted,
      lastUpdated: data.time_last_update_utc,
    });
  } catch (err) {
    const isTimeout = err.code === "ECONNABORTED" || err.message.includes("timeout");
    log("ERROR", "Exchange rate API request failed", {
      url,
      error: err.message,
      code: err.code,
      isTimeout,
      durationMs: Date.now() - t0,
    });
    res.status(502).json({ error: "Failed to fetch exchange rates", detail: err.message });
  }
});

/**
 * GET /files/read?file=ping.txt
 *
 * Reads a file from a private GCS bucket using Workload Identity Federation.
 * The Azure Managed Identity token is automatically exchanged for short-lived
 * GCP credentials by the Google Auth Library.
 */
app.get("/files/read", async (req, res) => {
  const fileName = req.query.file;
  if (!fileName) {
    return res.status(400).json({ error: "Missing required query parameter: file" });
  }

  const bucketName = process.env.GCS_BUCKET_NAME || "foca-assets";
  log("INFO", "Reading file from GCS", { bucket: bucketName, file: fileName });

  try {
    const contents = await readFile(bucketName, fileName);
    log("INFO", "File read from GCS", { bucket: bucketName, file: fileName });
    console.log(`--- GCS file contents (${fileName}) ---`);
    console.log(contents);
    console.log("--- end ---");
    res.json({ bucket: bucketName, file: fileName, contents });
  } catch (err) {
    log("ERROR", "Failed to read file from GCS", {
      bucket: bucketName,
      file: fileName,
      error: err.message,
    });
    res.status(500).json({ error: "Failed to read file from GCS", detail: err.message });
  }
});

// ─── 404 catch-all ───────────────────────────────────────────────────────────
app.use((req, res) => {
  log("WARN", "Route not found", { method: req.method, path: req.path });
  res.status(404).json({ error: "Route not found" });
});

module.exports = app;
