import assert from "node:assert/strict";
import test from "node:test";
import { buildGlobalCatalogQueries, createShopifyGlobalCatalogProvider, merchantDomain, normalizeGlobalCatalogProduct } from "../shopify-global-provider.mjs";

const product = {
  id: "gid://shopify/p/global-1", title: "Textured Women's Cardigan",
  description: { plain: "A softly textured cardigan for women." },
  media: [{ type: "image", url: "https://cdn.shopify.com/cardigan.jpg" }],
  price_range: { min: { amount: 7800, currency: "USD" } },
  options: [{ name: "Color", values: [{ label: "Plum" }] }],
  variants: [{
    id: "gid://shopify/ProductVariant/11", title: "Plum / M",
    url: "https://small-label.example/products/cardigan?variant=11&_gsid=tracking",
    price: { amount: 7800, currency: "USD" }, availability: { available: true }
  }]
};

const ok = value => new Response(JSON.stringify(value), { status: 200, headers: { "content-type": "application/json" } });
const result = structuredContent => ({ jsonrpc: "2.0", id: "1", result: { structuredContent } });
const validateURL = async value => new URL(String(value));

test("global products normalize variant-only merchant URLs and provenance", () => {
  const value = normalizeGlobalCatalogProduct(product);
  assert.equal(value.domain, "small-label.example");
  assert.equal(value.canonicalURL, "https://small-label.example/products/cardigan?variant=11");
  assert.equal(value.currentPrice, 78);
  assert.equal(value.currency, "USD");
  assert.equal(value.source, "ucp-global");
  assert.equal(value.globalCatalogProductID, product.id);
  assert.equal(value.globalCatalogVariantID, product.variants[0].id);
});

test("merchant identity collapses regional subdomains without breaking compound country suffixes", () => {
  assert.equal(merchantDomain("https://eu.bloomchic.com/products/top"), "bloomchic.com");
  assert.equal(merchantDomain("https://shop.example.co.uk/products/top"), "example.co.uk");
});

test("global query lanes use derived style descriptors without summaries or personal identifiers", () => {
  const queries = buildGlobalCatalogQueries({
    query: "a cardigan under $100",
    preferences: { clothingAudience: "women" },
    styleProfile: {
      summary: "PRIVATE PROFILE SUMMARY", aesthetics: ["romantic", "vintage"], palette: ["plum"],
      silhouettes: ["cropped"], layering: ["light layers"], details: ["texture"], vector: { romantic: 0.9, vintage: 0.7 }
    },
    inspirationExamples: [{ id: "PRIVATE-INSPIRATION-ID", summary: "PRIVATE LOOK SUMMARY", aesthetics: ["soft grunge"], silhouettes: ["fitted"] }]
  });
  assert.equal(queries.length, 4);
  const body = queries.join(" ");
  assert.match(body, /romantic|vintage/i);
  assert.doesNotMatch(body, /PRIVATE PROFILE SUMMARY|PRIVATE LOOK SUMMARY|PRIVATE-INSPIRATION-ID/);
});

test("global search sends only catalog descriptors and coarse shopping constraints", async () => {
  const requests = [];
  const provider = createShopifyGlobalCatalogProvider({
    validateURL,
    fetchImpl: async (_url, options) => {
      requests.push(JSON.parse(options.body));
      return ok(result({
        ucp: { status: "success" }, products: [product],
        pagination: { has_next_page: true, cursor: "next-page" }
      }));
    }
  });
  const page = await provider.searchCatalog({
    query: "women's romantic cropped cardigan", cursor: "current-page", limit: 25,
    preferences: { country: "US", currency: "USD", clothingAudience: "women", sizes: { tops: "M" }, budgets: { tops: 100 } }
  });
  assert.equal(page.products.length, 1);
  assert.equal(page.cursor, "next-page");
  const catalog = requests[0].params.arguments.catalog;
  assert.equal(catalog.pagination.cursor, "current-page");
  assert.equal(catalog.filters.available, true);
  assert.deepEqual(catalog.filters.ships_to, { country: "US" });
  assert.equal(catalog.filters.price.max, 10000);
  assert.equal(catalog.placements, undefined, "organic results do not request promoted placements");
  const serialized = JSON.stringify(requests[0]);
  assert.doesNotMatch(serialized, /wardrobe|garmentVisuals|inspirationVisuals|PRIVATE/i);
});

test("global search maps all three clothing audiences to target-gender filters", async () => {
  const filters = [];
  const provider = createShopifyGlobalCatalogProvider({
    validateURL,
    fetchImpl: async (_url, options) => {
      filters.push(JSON.parse(options.body).params.arguments.catalog.filters.attributes[0]);
      return ok(result({ ucp: { status: "success" }, products: [] }));
    }
  });
  for (const clothingAudience of ["women", "unisex", "men"]) {
    await provider.searchCatalog({ query: "shirt", preferences: { clothingAudience } });
  }
  assert.deepEqual(filters, [
    { name: "Target gender", values: ["Female"] },
    { name: "Target gender", values: ["Unisex"] },
    { name: "Target gender", values: ["Male"] }
  ]);
});

test("global search filters hidden retailers and unavailable variants", async () => {
  const unavailable = structuredClone(product);
  unavailable.id = "gid://shopify/p/unavailable";
  unavailable.variants[0].id = "gid://shopify/ProductVariant/12";
  unavailable.variants[0].availability.available = false;
  const provider = createShopifyGlobalCatalogProvider({
    validateURL,
    fetchImpl: async () => ok(result({ ucp: { status: "success" }, products: [product, unavailable] }))
  });
  const page = await provider.searchCatalog({
    query: "cardigan", preferences: { clothingAudience: "women", excludedRetailerDomains: ["small-label.example"] }
  });
  assert.deepEqual(page.products, []);
});

test("get_product revalidates the exact variant before publication", async () => {
  let request;
  const provider = createShopifyGlobalCatalogProvider({
    validateURL,
    fetchImpl: async (_url, options) => { request = JSON.parse(options.body); return ok(result({ ucp: { status: "success" }, product })); }
  });
  const value = await provider.getProduct({
    productID: product.id, variantID: product.variants[0].id,
    preferences: { country: "US", currency: "USD", clothingAudience: "women" }
  });
  assert.equal(value.globalCatalogVariantID, product.variants[0].id);
  assert.equal(request.params.name, "get_product");
  assert.equal(request.params.arguments.catalog.id, product.variants[0].id);
});

test("global provider rejects malformed and oversized protocol responses", async () => {
  const malformed = createShopifyGlobalCatalogProvider({
    validateURL,
    fetchImpl: async () => new Response("not-json", { status: 200, headers: { "content-type": "application/json" } })
  });
  await assert.rejects(malformed.searchCatalog({ query: "top" }), /malformed JSON/i);
  const oversized = createShopifyGlobalCatalogProvider({
    validateURL,
    fetchImpl: async () => new Response("{}", { status: 200, headers: { "content-type": "application/json", "content-length": "99999999" } })
  });
  await assert.rejects(oversized.searchCatalog({ query: "top" }), /too large/i);
});
