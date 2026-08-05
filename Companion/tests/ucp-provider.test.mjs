import assert from "node:assert/strict";
import test from "node:test";
import { createUCPShopProvider, normalizeUCPProduct, parseUCPMCPResponse, parseUCPProfile } from "../ucp-provider.mjs";

const profile = {
  ucp: {
    version: "2026-04-08",
    services: { "dev.ucp.shopping": [{ transport: "mcp", endpoint: "https://shop.myshopify.com/api/ucp/mcp" }] },
    capabilities: { "dev.ucp.shopping.catalog.search": [{ version: "2026-04-08" }] }
  }
};

const product = {
  id: "gid://shopify/Product/1", title: "Textured Layering Top", url: "https://shop.example/products/top",
  description: { plain: "A fitted ribbed layering top." },
  price_range: { min: { amount: 4200, currency: "USD" } },
  list_price_range: { min: { amount: 6200, currency: "USD" } },
  media: [{ type: "image", url: "https://cdn.shopify.com/top.jpg" }],
  options: [{ name: "Color", values: [{ label: "Plum" }] }],
  variants: [{ availability: { available: true }, price: { amount: 4200, currency: "USD" } }]
};

test("UCP profiles require catalog search and an MCP endpoint", () => {
  assert.equal(parseUCPProfile(profile, "shop.example").endpoint, "https://shop.myshopify.com/api/ucp/mcp");
  assert.throws(() => parseUCPProfile({ ucp: { capabilities: {}, services: {} } }, "shop.example"), /catalog search/i);
});

test("UCP products normalize minor-unit prices, media, identity, and provenance", () => {
  const value = normalizeUCPProduct(product, "shop.example");
  assert.equal(value.currentPrice, 42);
  assert.equal(value.originalPrice, 62);
  assert.equal(value.currency, "USD");
  assert.equal(value.source, "ucp");
  assert.equal(value.sourceProductID, product.id);
  assert.deepEqual(value.colors, ["Plum"]);
  const unavailable = structuredClone(product);
  unavailable.variants[0].availability.available = false;
  assert.throws(() => normalizeUCPProduct(unavailable, "shop.example"), /unavailable/i);
});

test("provider preserves a retailer-returned currency when the catalog cannot localize it", async () => {
  const foreignCurrencyProduct = structuredClone(product);
  foreignCurrencyProduct.price_range.min.currency = "CAD";
  foreignCurrencyProduct.list_price_range.min.currency = "CAD";
  foreignCurrencyProduct.variants[0].price.currency = "CAD";
  const fetchImpl = async url => {
    if (String(url).includes(".well-known")) return new Response(JSON.stringify(profile), { status: 200, headers: { "content-type": "application/json" } });
    return new Response(JSON.stringify({ result: { structuredContent: { products: [foreignCurrencyProduct] } } }), { status: 200, headers: { "content-type": "application/json" } });
  };
  const provider = createUCPShopProvider({ fetchImpl, validateURL: async value => new URL(String(value)) });
  const result = await provider.searchCatalog({ domain: "currency.example", query: "top", preferences: { currency: "USD" } });
  assert.equal(result.products[0].currency, "CAD");
  assert.equal(result.products[0].currentPrice, 42);
});

test("MCP text content is parsed as a structured catalog response", () => {
  const parsed = parseUCPMCPResponse({ result: { content: [{ type: "text", text: JSON.stringify({ products: [product], pagination: { has_next_page: true, cursor: "next" } }) }] } });
  assert.equal(parsed.products[0].id, product.id);
  assert.equal(parsed.pagination.cursor, "next");
  assert.throws(() => parseUCPMCPResponse({ error: { message: "rate limited" } }), /rate limited/i);
});

test("provider discovers the profile, searches without wardrobe data, and returns a cursor", async () => {
  const requests = [];
  const fetchImpl = async (url, options = {}) => {
    requests.push({ url: String(url), options });
    if (String(url).includes(".well-known")) return new Response(JSON.stringify(profile), { status: 200, headers: { "content-type": "application/json" } });
    const response = { jsonrpc: "2.0", id: "1", result: { content: [{ type: "text", text: JSON.stringify({
      ucp: { status: "success" }, products: [product], pagination: { has_next_page: true, cursor: "next" }
    }) }] } };
    return new Response(JSON.stringify(response), { status: 200, headers: { "content-type": "application/json" } });
  };
  const provider = createUCPShopProvider({ fetchImpl, validateURL: async value => new URL(String(value)), now: () => 1 });
  const result = await provider.searchCatalog({ domain: "shop.example", query: "layering top", preferences: { country: "US", currency: "USD", budgets: { tops: 80 } }, limit: 3 });
  assert.equal(result.products.length, 1);
  assert.equal(result.cursor, "next");
  const body = requests[1].options.body;
  assert.match(body, /layering top/);
  assert.match(body, /women's or unisex/i);
  assert.doesNotMatch(body, /wardrobe|inspiration/i);
});

test("UCP catalog removes explicit men's products but keeps unisex products", async () => {
  const mens = structuredClone(product);
  mens.id = "gid://shopify/Product/mens"; mens.title = "Men's Woven Shirt"; mens.url = "https://shop.example/products/mens-woven-shirt";
  const unisex = structuredClone(product);
  unisex.id = "gid://shopify/Product/unisex"; unisex.title = "Unisex Woven Shirt"; unisex.url = "https://shop.example/products/unisex-woven-shirt";
  const fetchImpl = async url => String(url).includes(".well-known")
    ? new Response(JSON.stringify(profile), { status: 200, headers: { "content-type": "application/json" } })
    : new Response(JSON.stringify({ result: { structuredContent: { products: [mens, unisex] } } }), { status: 200, headers: { "content-type": "application/json" } });
  const provider = createUCPShopProvider({ fetchImpl, validateURL: async value => new URL(String(value)) });
  const result = await provider.searchCatalog({ domain: "shop.example", query: "shirt", preferences: {} });
  assert.deepEqual(result.products.map(item => item.sourceProductID), [unisex.id]);
});

test("unsafe advertised UCP endpoints are rejected before catalog calls", async () => {
  const unsafe = structuredClone(profile); unsafe.ucp.services["dev.ucp.shopping"][0].endpoint = "http://127.0.0.1/ucp";
  const provider = createUCPShopProvider({
    fetchImpl: async () => new Response(JSON.stringify(unsafe), { status: 200, headers: { "content-type": "application/json" } }),
    validateURL: async value => { const url = new URL(String(value)); if (url.protocol !== "https:") throw new Error("unsafe"); return url; }
  });
  await assert.rejects(provider.profileFor("unsafe.example"), /unsafe/);
});

test("oversized UCP profiles are rejected before parsing", async () => {
  const provider = createUCPShopProvider({
    fetchImpl: async () => new Response("{}", { status: 200, headers: { "content-type": "application/json", "content-length": "999999" } }),
    validateURL: async value => new URL(String(value))
  });
  await assert.rejects(provider.profileFor("large.example"), /too large/i);
});
