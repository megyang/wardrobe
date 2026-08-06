import crypto from "node:crypto";
import { assertSafeHTTPSURL, normalizeCategory, normalizeDomain } from "./shop-discovery.mjs";
import { allowsShoppingAudience, shoppingAudienceLabel } from "./shop-feed.mjs";
import { DEVELOPMENT_UCP_AGENT_PROFILE, parseUCPMCPResponse } from "./ucp-provider.mjs";

export const SHOPIFY_GLOBAL_CATALOG_ENDPOINT = "https://catalog.shopify.com/api/ucp/mcp";
const RESPONSE_MAX_BYTES = 8 * 1024 * 1024;
const PAGE_LIMIT = 25;

async function responseBytes(response, limit) {
  const declared = Number(response.headers?.get?.("content-length") || 0);
  if (declared > limit) throw new Error("The Global Catalog response is too large.");
  const reader = response.body?.getReader?.();
  if (!reader) {
    const bytes = Buffer.from(await response.arrayBuffer());
    if (bytes.length > limit) throw new Error("The Global Catalog response is too large.");
    return bytes;
  }
  const chunks = []; let total = 0;
  while (true) {
    const { done, value } = await reader.read();
    if (done) break;
    total += value.length;
    if (total > limit) { await reader.cancel(); throw new Error("The Global Catalog response is too large."); }
    chunks.push(Buffer.from(value));
  }
  return Buffer.concat(chunks);
}

async function requestJSON(payload, signal, { fetchImpl, validateURL }) {
  const endpoint = await validateURL(SHOPIFY_GLOBAL_CATALOG_ENDPOINT, ["catalog.shopify.com"]);
  const response = await fetchImpl(endpoint, {
    method: "POST", redirect: "error", signal,
    headers: { "content-type": "application/json", accept: "application/json" },
    body: JSON.stringify(payload)
  });
  if (!response.ok) throw new Error(`Shopify Global Catalog returned HTTP ${response.status}.`);
  const type = String(response.headers?.get?.("content-type") || "").toLowerCase();
  if (type && !type.includes("json")) throw new Error("Shopify Global Catalog did not return JSON.");
  try { return JSON.parse((await responseBytes(response, RESPONSE_MAX_BYTES)).toString("utf8")); }
  catch (error) {
    if (/too large/i.test(error?.message || "")) throw error;
    throw new Error("Shopify Global Catalog returned malformed JSON.");
  }
}

function cleanTerms(values, limit) {
  return [...new Set((values || []).map(value => String(value).replace(/\s+/g, " ").trim()).filter(Boolean))].slice(0, limit);
}

function topVectorTerms(vector) {
  return Object.entries(vector || {})
    .filter(([, value]) => Number.isFinite(Number(value)) && Number(value) > 0.12)
    .sort((a, b) => Number(b[1]) - Number(a[1]))
    .slice(0, 4).map(([key]) => key);
}

export function buildGlobalCatalogQueries({ query, preferences = {}, styleProfile = null, inspirationExamples = [] }) {
  const audience = shoppingAudienceLabel(preferences);
  const exact = String(query || "personalized clothing").replace(/\s+/g, " ").trim().slice(0, 360);
  const focused = inspirationExamples.flatMap(item => [
    ...(item.aesthetics || []), ...(item.silhouettes || []), ...(item.palette || []), ...(item.details || [])
  ]);
  const aesthetics = cleanTerms([...(styleProfile?.aesthetics || []), ...focused], 7);
  const silhouettes = cleanTerms([...(styleProfile?.silhouettes || []), ...inspirationExamples.flatMap(item => item.silhouettes || [])], 4);
  const palette = cleanTerms([...(styleProfile?.palette || []), ...inspirationExamples.flatMap(item => item.palette || [])], 4);
  const layering = cleanTerms([...(styleProfile?.layering || []), ...(styleProfile?.outfitFormula || [])], 4);
  const details = cleanTerms([...(styleProfile?.details || []), ...(styleProfile?.focalPoints || [])], 5);
  const vector = topVectorTerms(styleProfile?.vector);
  const join = values => cleanTerms(values, 12).join(", ");
  const lanes = [
    exact,
    `${audience} clothing, core style: ${join([...vector, ...aesthetics, ...silhouettes])}`,
    `${audience} versatile outfit-building piece, ${join([...layering, ...palette, ...silhouettes])}`,
    `${audience} distinctive but wearable clothing, ${join([...details, ...aesthetics.slice(-3), ...palette])}`
  ];
  return [...new Set(lanes.map(value => value.replace(/,\s*$/, "").trim()).filter(value => value.length > 8))].slice(0, 4);
}

function firstAvailableVariant(product, expectedVariantID = null) {
  const variants = product?.variants || [];
  if (expectedVariantID) {
    const expected = variants.find(item => String(item?.id) === String(expectedVariantID) && item?.availability?.available !== false);
    if (expected) return expected;
  }
  return variants.find(item => item?.availability?.available !== false && (item?.url || product?.url)) || variants[0] || null;
}

function firstImage(product, variant) {
  return [...(variant?.media || []), ...(product?.media || [])].find(item => item?.type === "image" && item?.url)?.url || null;
}

function money(value) {
  const amount = Number(value?.amount);
  return Number.isFinite(amount) && amount >= 0 ? amount / 100 : null;
}

function retailerName(domain) {
  return domain.split(".")[0].split(/[-_]/).filter(Boolean).map(value => value[0]?.toUpperCase() + value.slice(1)).join(" ") || domain;
}

export function merchantDomain(value) {
  const normalized = normalizeDomain(value);
  if (!normalized) return null;
  const parts = normalized.split(".");
  if (parts.length <= 2) return normalized;
  const compoundSuffixes = new Set(["co.uk", "org.uk", "com.au", "com.br", "com.mx", "co.jp", "co.kr", "co.nz", "co.za"]);
  const suffix = parts.slice(-2).join(".");
  return parts.slice(compoundSuffixes.has(suffix) ? -3 : -2).join(".");
}

function canonicalVariantURL(value) {
  const url = new URL(String(value));
  for (const key of [...url.searchParams.keys()]) {
    if (key.startsWith("utm_") || ["_gsid", "ref", "source"].includes(key)) url.searchParams.delete(key);
  }
  return url.href;
}

export function normalizeGlobalCatalogProduct(product, { expectedVariantID = null } = {}) {
  const variant = firstAvailableVariant(product, expectedVariantID);
  const rawURL = variant?.url || product?.url;
  const domain = merchantDomain(rawURL);
  const imageURL = String(firstImage(product, variant) || "");
  const productID = String(product?.id || ""); const variantID = String(variant?.id || "");
  const canonicalURL = rawURL ? canonicalVariantURL(rawURL) : "";
  const currentPrice = money(variant?.price) ?? money(product?.price_range?.min);
  const original = money(variant?.list_price) ?? money(product?.list_price_range?.min);
  const currency = String(variant?.price?.currency || product?.price_range?.min?.currency || "").toUpperCase();
  if (!productID || !variantID || !domain || !canonicalURL || !imageURL || !product?.title || currentPrice == null || !currency) {
    throw new Error("Global Catalog product identity, merchant, media, or price is incomplete.");
  }
  if (variant?.availability?.available === false) throw new Error("Global Catalog product is unavailable.");
  const description = String(product?.description?.plain || product?.description?.html || variant?.description?.plain || variant?.description?.html || "")
    .replace(/<[^>]+>/g, " ").replace(/\s+/g, " ").trim();
  const colors = [...new Set((product?.options || [])
    .filter(item => String(item?.name || "").toLowerCase() === "color")
    .flatMap(item => (item?.values || []).map(value => String(value?.label || "")).filter(Boolean)))].slice(0, 8);
  return {
    id: crypto.createHash("sha256").update(`shopify-global:${productID}:${variantID}`).digest("hex").slice(0, 24),
    canonicalURL, retailer: String(variant?.seller?.name || product?.seller?.name || retailerName(domain)), domain,
    title: String(product.title), imageURL,
    category: normalizeCategory(`${product.title} ${description} ${(product?.categories || []).map(item => item?.value || item).join(" ")}`),
    colors, currentPrice, originalPrice: original != null && original > currentPrice ? original : null, currency,
    verifiedAt: new Date().toISOString(), confidence: 0.96, description: description.slice(0, 700),
    source: "ucp-global", sourceProductID: productID,
    globalCatalogProductID: productID, globalCatalogVariantID: variantID
  };
}

function catalogFilters(preferences) {
  const budgets = Object.values(preferences?.budgets || {}).map(Number).filter(value => Number.isFinite(value) && value > 0);
  const sizes = cleanTerms(Object.values(preferences?.sizes || {}), 12);
  const gender = { women: "Female", men: "Male", unisex: "Unisex" }[String(preferences?.clothingAudience || "women")] || "Female";
  return {
    available: true,
    ships_to: { country: String(preferences?.country || "US").toUpperCase() },
    ...(budgets.length ? { price: { max: Math.round(Math.max(...budgets) * 100) } } : {}),
    attributes: [
      { name: "Target gender", values: [gender] },
      ...(sizes.length ? [{ name: "Size", values: sizes }] : [])
    ]
  };
}

function toolPayload(name, catalog, agentProfile) {
  return {
    jsonrpc: "2.0", method: "tools/call", id: crypto.randomUUID(),
    params: { name, arguments: { meta: { "ucp-agent": { profile: agentProfile } }, catalog } }
  };
}

export function createShopifyGlobalCatalogProvider({
  fetchImpl = fetch, validateURL = assertSafeHTTPSURL, agentProfile = DEVELOPMENT_UCP_AGENT_PROFILE
} = {}) {
  async function normalizeProducts(values, preferences, expectedVariantID = null) {
    const excluded = new Set((preferences?.excludedRetailerDomains || []).map(merchantDomain).filter(Boolean));
    const settled = await Promise.allSettled((values || []).map(async value => {
      const product = normalizeGlobalCatalogProduct(value, { expectedVariantID });
      if (excluded.has(product.domain) || !allowsShoppingAudience(product, preferences)) throw new Error("Product is outside the selected audience or retailer policy.");
      await validateURL(product.canonicalURL, [product.domain]);
      await validateURL(product.imageURL);
      return product;
    }));
    return settled.filter(item => item.status === "fulfilled").map(item => item.value);
  }

  async function searchCatalog({ query, preferences = {}, cursor = null, limit = PAGE_LIMIT, signal }) {
    const catalog = {
      query: String(query || "").slice(0, 500), view: "offer",
      context: {
        address_country: String(preferences.country || "US").toUpperCase(),
        currency: String(preferences.currency || "USD").toUpperCase(),
        intent: `Find high-quality ${shoppingAudienceLabel(preferences)} clothing matching this non-identifying style request.`
      },
      filters: catalogFilters(preferences),
      pagination: { limit: Math.max(1, Math.min(50, limit)), ...(cursor ? { cursor } : {}) }
    };
    const raw = await requestJSON(toolPayload("search_catalog", catalog, agentProfile), signal, { fetchImpl, validateURL });
    const result = parseUCPMCPResponse(raw);
    if (result?.ucp?.status === "error") throw new Error(String(result.messages?.[0]?.content || "Global Catalog search failed."));
    return {
      products: await normalizeProducts(result?.products, preferences),
      cursor: result?.pagination?.has_next_page && result?.pagination?.cursor ? String(result.pagination.cursor) : null,
      hasMore: Boolean(result?.pagination?.has_next_page && result?.pagination?.cursor)
    };
  }

  async function getProduct({ productID, variantID, preferences = {}, signal }) {
    const catalog = {
      id: String(variantID || productID),
      filters: { ships_to: { country: String(preferences.country || "US").toUpperCase() } },
      context: {
        address_country: String(preferences.country || "US").toUpperCase(),
        currency: String(preferences.currency || "USD").toUpperCase()
      }
    };
    const raw = await requestJSON(toolPayload("get_product", catalog, agentProfile), signal, { fetchImpl, validateURL });
    const result = parseUCPMCPResponse(raw);
    if (result?.ucp?.status === "error" || !result?.product) throw new Error(String(result?.messages?.[0]?.content || "Global Catalog product revalidation failed."));
    const products = await normalizeProducts([result.product], preferences, variantID);
    if (!products.length) throw new Error("The Global Catalog product is no longer available.");
    return products[0];
  }

  return Object.freeze({ id: "shopify-global", searchCatalog, getProduct });
}
