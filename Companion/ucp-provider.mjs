import crypto from "node:crypto";
import { assertSafeHTTPSURL, normalizeCategory, normalizeDomain } from "./shop-discovery.mjs";
import { allowsShoppingAudience, audienceConstrainedQuery, shoppingAudienceLabel } from "./shop-feed.mjs";

// Shopify documents this profile only for development/testing. Keep it isolated
// so a production build cannot accidentally hide the need for Wearwell's own URL.
export const DEVELOPMENT_UCP_AGENT_PROFILE = process.env.WEARWELL_UCP_AGENT_PROFILE ||
  "https://shopify.dev/ucp/agent-profiles/examples/2026-04-08/valid-with-capabilities.json";

const PROFILE_TTL_MS = 24 * 60 * 60 * 1000;
const PROFILE_MAX_BYTES = 256 * 1024;
const CATALOG_MAX_BYTES = 6 * 1024 * 1024;
const profileCache = new Map();

async function responseBytes(response, limit) {
  const declared = Number(response.headers?.get?.("content-length") || 0);
  if (declared > limit) throw new Error("The UCP response is too large.");
  const reader = response.body?.getReader?.();
  if (!reader) {
    const bytes = Buffer.from(await response.arrayBuffer());
    if (bytes.length > limit) throw new Error("The UCP response is too large.");
    return bytes;
  }
  const chunks = []; let total = 0;
  while (true) {
    const { done, value } = await reader.read();
    if (done) break;
    total += value.length;
    if (total > limit) { await reader.cancel(); throw new Error("The UCP response is too large."); }
    chunks.push(Buffer.from(value));
  }
  return Buffer.concat(chunks);
}

async function requestJSON(url, options, { fetchImpl, validateURL, maxBytes }) {
  let safe = await validateURL(url);
  for (let redirect = 0; redirect <= 4; redirect++) {
    const response = await fetchImpl(safe, { ...options, redirect: "manual" });
    if ([301, 302, 303, 307, 308].includes(response.status)) {
      const location = response.headers?.get?.("location");
      if (!location || redirect === 4) throw new Error("The UCP endpoint redirected too many times.");
      safe = await validateURL(new URL(location, safe));
      continue;
    }
    if (!response.ok) throw new Error(`UCP returned HTTP ${response.status}.`);
    const type = String(response.headers?.get?.("content-type") || "").toLowerCase();
    if (type && !type.includes("json")) throw new Error("The UCP endpoint did not return JSON.");
    const bytes = await responseBytes(response, maxBytes);
    try { return JSON.parse(bytes.toString("utf8")); }
    catch { throw new Error("The UCP endpoint returned malformed JSON."); }
  }
  throw new Error("The UCP endpoint could not be reached.");
}

function catalogCapability(profile) {
  return profile?.ucp?.capabilities?.["dev.ucp.shopping.catalog.search"];
}

export function parseUCPProfile(profile, domain) {
  if (!Array.isArray(catalogCapability(profile)) || !catalogCapability(profile).length) {
    throw new Error(`${domain} does not advertise UCP catalog search.`);
  }
  const services = profile?.ucp?.services?.["dev.ucp.shopping"];
  const service = Array.isArray(services) ? services.find(item => item?.transport === "mcp" && item?.endpoint) : null;
  if (!service) throw new Error(`${domain} does not advertise a UCP MCP endpoint.`);
  return { domain, version: String(profile.ucp.version || ""), endpoint: new URL(String(service.endpoint)).href };
}

export function parseUCPMCPResponse(value) {
  if (value?.error) throw new Error(String(value.error.message || "The UCP catalog request failed."));
  if (value?.result?.structuredContent && typeof value.result.structuredContent === "object") return value.result.structuredContent;
  for (const item of value?.result?.content || []) {
    if (item?.type !== "text" || typeof item.text !== "string") continue;
    try { return JSON.parse(item.text); } catch { /* try the next content item */ }
  }
  throw new Error("The UCP catalog response did not contain structured products.");
}

function firstImage(product) {
  const candidates = [...(product?.media || []), ...(product?.variants || []).flatMap(item => item?.media || [])];
  return candidates.find(item => item?.type === "image" && item?.url)?.url || null;
}

function firstAvailableVariant(product) {
  return (product?.variants || []).find(item => item?.availability?.available !== false) || product?.variants?.[0] || null;
}

function money(value) {
  const amount = Number(value?.amount);
  return Number.isFinite(amount) && amount >= 0 ? amount / 100 : null;
}

export function normalizeUCPProduct(product, retailerDomain) {
  const canonicalURL = String(product?.url || "");
  const imageURL = String(firstImage(product) || "");
  const sourceProductID = String(product?.id || "");
  if (!sourceProductID || !canonicalURL || !imageURL || !product?.title) throw new Error("UCP product identity or media is incomplete.");
  if ((product?.variants || []).length && product.variants.every(item => item?.availability?.available === false)) {
    throw new Error("UCP product is unavailable.");
  }
  const variant = firstAvailableVariant(product);
  const current = money(product?.price_range?.min) ?? money(variant?.price);
  const original = money(product?.list_price_range?.min);
  const currency = String(product?.price_range?.min?.currency || variant?.price?.currency || "").toUpperCase() || null;
  const colors = [...new Set((product?.options || [])
    .filter(item => String(item?.name || "").toLowerCase() === "color")
    .flatMap(item => (item?.values || []).map(value => String(value?.label || "")).filter(Boolean)))].slice(0, 8);
  const description = String(product?.description?.plain || product?.description?.html || "").replace(/<[^>]+>/g, " ").replace(/\s+/g, " ").trim();
  return {
    id: crypto.createHash("sha256").update(`${retailerDomain}:${sourceProductID}`).digest("hex").slice(0, 24),
    canonicalURL, retailer: String(product?.seller?.name || retailerDomain.split(".")[0]), domain: retailerDomain,
    title: String(product.title), imageURL, category: normalizeCategory(`${product.title} ${description} ${(product.tags || []).join(" ")}`),
    colors, currentPrice: current, originalPrice: original != null && current != null && original > current ? original : null,
    currency, verifiedAt: new Date().toISOString(), confidence: 0.98, description: description.slice(0, 700),
    source: "ucp", sourceProductID
  };
}

export function createUCPShopProvider({
  fetchImpl = fetch,
  validateURL = assertSafeHTTPSURL,
  agentProfile = DEVELOPMENT_UCP_AGENT_PROFILE,
  now = () => Date.now()
} = {}) {
  async function profileFor(domain, signal) {
    const normalized = normalizeDomain(domain);
    if (!normalized) throw new Error("Invalid retailer domain.");
    const cached = profileCache.get(normalized);
    if (cached && now() - cached.savedAt < PROFILE_TTL_MS) return cached.value;
    const raw = await requestJSON(`https://${normalized}/.well-known/ucp`, { signal }, { fetchImpl, validateURL, maxBytes: PROFILE_MAX_BYTES });
    const value = parseUCPProfile(raw, normalized);
    await validateURL(value.endpoint);
    profileCache.set(normalized, { savedAt: now(), value });
    return value;
  }

  async function searchCatalog({ domain, query, preferences = {}, cursor = null, limit = 3, signal }) {
    const profile = await profileFor(domain, signal);
    const budgets = Object.values(preferences.budgets || {}).map(Number).filter(value => Number.isFinite(value) && value > 0);
    const filters = budgets.length ? { price: { max: Math.round(Math.max(...budgets) * 100) } } : undefined;
    const catalog = {
      query: audienceConstrainedQuery(query, preferences).slice(0, 500),
      context: {
        address_country: String(preferences.country || "US").toUpperCase(),
        currency: String(preferences.currency || "USD").toUpperCase(),
        intent: `Find only ${shoppingAudienceLabel(preferences)} clothing matching the shopper's stated request and regional constraints. Exclude products for other audiences.`
      },
      pagination: { limit: Math.max(1, Math.min(12, limit)), ...(cursor ? { cursor } : {}) },
      ...(filters ? { filters } : {})
    };
    const payload = {
      jsonrpc: "2.0", method: "tools/call", id: crypto.randomUUID(),
      params: { name: "search_catalog", arguments: { meta: { "ucp-agent": { profile: agentProfile } }, catalog } }
    };
    const raw = await requestJSON(profile.endpoint, {
      method: "POST", signal, headers: { "content-type": "application/json", accept: "application/json" }, body: JSON.stringify(payload)
    }, { fetchImpl, validateURL, maxBytes: CATALOG_MAX_BYTES });
    const result = parseUCPMCPResponse(raw);
    if (result?.ucp?.status === "error") throw new Error(String(result.messages?.[0]?.content || "UCP catalog search failed."));
    const products = [];
    for (const value of result?.products || []) {
      try {
        const product = normalizeUCPProduct(value, profile.domain);
        if (!allowsShoppingAudience(product, preferences)) continue;
        await validateURL(product.canonicalURL, [profile.domain]);
        await validateURL(product.imageURL);
        products.push(product);
      } catch { /* one malformed catalog row must not discard the page */ }
    }
    return {
      products,
      cursor: result?.pagination?.has_next_page && result?.pagination?.cursor ? String(result.pagination.cursor) : null,
      hasMore: Boolean(result?.pagination?.has_next_page && result?.pagination?.cursor)
    };
  }

  return Object.freeze({ id: "ucp", profileFor, searchCatalog });
}
