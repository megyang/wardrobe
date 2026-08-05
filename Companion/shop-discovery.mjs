import crypto from "node:crypto";
import dns from "node:dns/promises";
import net from "node:net";

export const BUNDLED_RETAILERS = Object.freeze([
  { name: "Aritzia", domain: "aritzia.com" },
  { name: "Uniqlo", domain: "uniqlo.com" },
  { name: "Hollister", domain: "hollisterco.com" },
  { name: "Canton Collective", domain: "cantoncollective.com" },
  { name: "Codibook", domain: "codibook.net" }
]);

const MAX_PAGE_BYTES = 1_500_000;
const MAX_IMAGE_BYTES = 4_000_000;
const REDIRECT_LIMIT = 4;

export function normalizeDomain(value) {
  const text = String(value || "").trim().toLowerCase();
  if (!text) return null;
  try {
    const url = new URL(text.includes("://") ? text : `https://${text}`);
    if (url.protocol !== "https:" || !url.hostname.includes(".") || net.isIP(url.hostname)) return null;
    return url.hostname.replace(/^www\./, "").replace(/\.$/, "");
  } catch { return null; }
}

export function isPrivateAddress(address) {
  if (net.isIPv4(address)) {
    const parts = address.split(".").map(Number);
    return parts[0] === 10 || parts[0] === 127 || parts[0] === 0 ||
      (parts[0] === 100 && parts[1] >= 64 && parts[1] <= 127) ||
      (parts[0] === 169 && parts[1] === 254) || (parts[0] === 172 && parts[1] >= 16 && parts[1] <= 31) ||
      (parts[0] === 192 && (parts[1] === 0 || parts[1] === 168)) ||
      (parts[0] === 198 && (parts[1] === 18 || parts[1] === 19 || (parts[1] === 51 && parts[2] === 100))) ||
      (parts[0] === 203 && parts[1] === 0 && parts[2] === 113) || parts[0] >= 224;
  }
  if (net.isIPv6(address)) {
    const value = address.toLowerCase();
    return value === "::" || value === "::1" || value.startsWith("fc") || value.startsWith("fd") || value.startsWith("ff") ||
      value.startsWith("fe8") || value.startsWith("fe9") || value.startsWith("fea") || value.startsWith("feb") ||
      value.startsWith("2001:db8:") || value.startsWith("::ffff:127.") || value.startsWith("::ffff:10.") || value.startsWith("::ffff:192.168.");
  }
  return true;
}

export async function assertSafeHTTPSURL(value, allowedDomains = null) {
  const url = value instanceof URL ? value : new URL(String(value));
  if (url.protocol !== "https:" || url.username || url.password || url.port) throw new Error("Only public HTTPS URLs are supported.");
  const hostname = url.hostname.toLowerCase().replace(/\.$/, "");
  if (net.isIP(hostname) || hostname === "localhost") throw new Error("Private network URLs are not supported.");
  if (allowedDomains?.length && !allowedDomains.some(domain => hostname === domain || hostname.endsWith(`.${domain}`))) {
    throw new Error("The product URL is outside the selected retailers.");
  }
  const addresses = await dns.lookup(hostname, { all: true, verbatim: true });
  if (!addresses.length || addresses.some(item => isPrivateAddress(item.address))) throw new Error("The product URL resolved to a private network.");
  return url;
}

async function limitedFetch(value, { allowedDomains = null, maxBytes, expectedType, signal }) {
  let url = await assertSafeHTTPSURL(value, allowedDomains);
  for (let redirect = 0; redirect <= REDIRECT_LIMIT; redirect++) {
    const response = await fetch(url, {
      redirect: "manual", signal,
      headers: { "user-agent": "Wearwell/1.0 product metadata verifier", accept: expectedType === "image" ? "image/*" : "text/html,application/xhtml+xml" }
    });
    if ([301, 302, 303, 307, 308].includes(response.status)) {
      const location = response.headers.get("location");
      if (!location || redirect === REDIRECT_LIMIT) throw new Error("The retailer redirected too many times.");
      url = await assertSafeHTTPSURL(new URL(location, url), allowedDomains);
      continue;
    }
    if (!response.ok) throw new Error(`The retailer returned HTTP ${response.status}.`);
    const type = (response.headers.get("content-type") || "").toLowerCase();
    if (expectedType === "image" ? !type.startsWith("image/") : !(type.includes("text/html") || type.includes("application/xhtml+xml"))) {
      throw new Error("The retailer returned an unsupported content type.");
    }
    const declared = Number(response.headers.get("content-length") || 0);
    if (declared > maxBytes) throw new Error("The retailer response is too large.");
    const reader = response.body?.getReader(); const chunks = []; let total = 0;
    if (!reader) throw new Error("The retailer returned an empty response.");
    while (true) {
      const { done, value: chunk } = await reader.read();
      if (done) break;
      total += chunk.length;
      if (total > maxBytes) { await reader.cancel(); throw new Error("The retailer response is too large."); }
      chunks.push(chunk);
    }
    return { url, type, bytes: Buffer.concat(chunks.map(chunk => Buffer.from(chunk))) };
  }
  throw new Error("The retailer redirect could not be resolved.");
}

export async function fetchProductImage(url, signal) {
  return limitedFetch(url, { maxBytes: MAX_IMAGE_BYTES, expectedType: "image", signal });
}

export async function verifyProductPage(value, allowedDomains, signal) {
  const response = await limitedFetch(value, { allowedDomains, maxBytes: MAX_PAGE_BYTES, expectedType: "html", signal });
  const product = parseProductHTML(response.bytes.toString("utf8"), response.url);
  await assertSafeHTTPSURL(product.canonicalURL, allowedDomains);
  await assertSafeHTTPSURL(product.imageURL);
  return product;
}

export function parseProductHTML(html, pageURL) {
  const base = pageURL instanceof URL ? pageURL : new URL(String(pageURL));
  const metas = metaValues(html);
  const canonicalValue = linkValue(html, "canonical") || metas.get("og:url");
  if (!canonicalValue) throw new Error("The page does not expose a canonical product URL.");
  let canonical;
  try { canonical = new URL(decodeHTML(canonicalValue), base); } catch { canonical = base; }
  if (canonical.protocol !== "https:") throw new Error("The canonical product URL is not HTTPS.");

  const product = jsonLDObjects(html).map(findProduct).find(Boolean);
  const offer = Array.isArray(product?.offers) ? product.offers[0] : product?.offers;
  const currentPrice = firstNumber(offer?.price, offer?.lowPrice, product?.offers?.price, metas.get("product:price:amount"));
  const priceCandidates = [
    ...numbersFromPriceSpecification(offer?.priceSpecification),
    ...numbersFromPriceSpecification(product?.offers?.priceSpecification),
    ...shopifyCompareAtPrices(html)
  ].filter(value => Number.isFinite(value) && value > 0).map(value =>
    currentPrice && value > 1000 && value > currentPrice * 10 && value / 100 > currentPrice ? value / 100 : value
  );
  const originalPrice = priceCandidates.filter(value => currentPrice && value > currentPrice).sort((a, b) => b - a)[0] ?? null;
  const title = cleanText(product?.name || metas.get("og:title") || titleValue(html));
  const imageValue = Array.isArray(product?.image) ? product.image[0] : (product?.image?.url || product?.image || metas.get("og:image"));
  let imageURL = "";
  if (imageValue) try { imageURL = new URL(decodeHTML(String(imageValue)), base).href; } catch { /* rejected below */ }
  if (!title || !imageURL || !canonical.hostname) throw new Error("The page does not expose enough product metadata.");
  const currency = String(offer?.priceCurrency || product?.offers?.priceCurrency || metas.get("product:price:currency") || "").toUpperCase() || null;
  const colors = values(product?.color).map(cleanText).filter(Boolean).slice(0, 8);
  const categoryText = cleanText(product?.category || metas.get("product:category") || "");
  const description = cleanText(product?.description || metas.get("og:description") || "");
  const domain = normalizeDomain(base.hostname);
  const siteName = cleanText(metas.get("og:site_name") || "");
  const retailer = siteName || titleCase((domain || base.hostname).split(".")[0]);
  return {
    id: crypto.createHash("sha256").update(canonical.href).digest("hex").slice(0, 24),
    canonicalURL: canonical.href, retailer, domain, title, imageURL,
    category: normalizeCategory(`${categoryText} ${title} ${description}`), colors,
    currentPrice: currentPrice ?? null, originalPrice, currency,
    verifiedAt: new Date().toISOString(), confidence: product ? 0.92 : 0.68,
    description: description.slice(0, 500)
  };
}

function jsonLDObjects(html) {
  const values = [];
  for (const match of html.matchAll(/<script\b[^>]*type=["']application\/ld\+json["'][^>]*>([\s\S]*?)<\/script>/gi)) {
    try { const parsed = JSON.parse(decodeHTML(match[1].trim())); values.push(...(Array.isArray(parsed) ? parsed : [parsed])); } catch { /* malformed metadata is ignored */ }
  }
  return values;
}

function findProduct(value) {
  if (!value || typeof value !== "object") return null;
  const types = values(value["@type"]).map(item => String(item).toLowerCase());
  if (types.includes("product")) return value;
  if (Array.isArray(value["@graph"])) return value["@graph"].map(findProduct).find(Boolean) || null;
  return null;
}

function metaValues(html) {
  const result = new Map();
  for (const match of html.matchAll(/<meta\b([^>]+)>/gi)) {
    const attrs = attributes(match[1]); const key = (attrs.property || attrs.name || "").toLowerCase();
    if (key && attrs.content && !result.has(key)) result.set(key, decodeHTML(attrs.content));
  }
  return result;
}

function attributes(text) {
  const result = {};
  for (const match of text.matchAll(/([\w:-]+)\s*=\s*(["'])(.*?)\2/gs)) result[match[1].toLowerCase()] = match[3];
  return result;
}

function linkValue(html, rel) {
  for (const match of html.matchAll(/<link\b([^>]+)>/gi)) {
    const attrs = attributes(match[1]);
    if ((attrs.rel || "").toLowerCase().split(/\s+/).includes(rel) && attrs.href) return attrs.href;
  }
  return null;
}

function titleValue(html) { return html.match(/<title[^>]*>([\s\S]*?)<\/title>/i)?.[1] || ""; }
function values(value) { return value == null ? [] : Array.isArray(value) ? value : [value]; }
function cleanText(value) { return decodeHTML(String(value || "").replace(/<[^>]+>/g, " ").replace(/\s+/g, " ").trim()); }
function firstNumber(...values) { return values.map(numberValue).find(value => value != null) ?? null; }
function numberValue(value) { const parsed = Number(String(value ?? "").replace(/[^0-9.-]/g, "")); return Number.isFinite(parsed) && parsed > 0 ? parsed : null; }
function numbersFromPriceSpecification(value) { return values(value).flatMap(item => item && typeof item === "object" ? [numberValue(item.price), numberValue(item.maxPrice)].filter(Boolean) : []); }
function shopifyCompareAtPrices(html) { return [...html.matchAll(/["']compare_at_price["']\s*:\s*["']?([0-9]+(?:\.[0-9]+)?)/gi)].map(match => numberValue(match[1])).filter(Boolean); }
function decodeHTML(value) { return String(value || "").replaceAll("&amp;", "&").replaceAll("&quot;", "\"").replaceAll("&#39;", "'").replaceAll("&lt;", "<").replaceAll("&gt;", ">"); }
function titleCase(value) { return value ? value[0].toUpperCase() + value.slice(1) : "Retailer"; }
function normalizeCategory(value) {
  const text = value.toLowerCase();
  if (/dress|jumpsuit/.test(text)) return "dresses";
  if (/shoe|boot|loafer|sneaker|heel|flat/.test(text)) return "shoes";
  if (/pant|jean|skirt|short|trouser|bottom/.test(text)) return "bottoms";
  if (/coat|jacket|cardigan|sweater|outerwear|blazer/.test(text)) return "outerwear";
  if (/bag|hat|belt|scarf|tight|sock|jewel|accessor/.test(text)) return "accessories";
  return "tops";
}
