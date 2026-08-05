import assert from "node:assert/strict";
import test from "node:test";
import { createLiveWebShopProvider } from "../shop-provider.mjs";

test("shop providers enforce selected domains and deduplicate canonical products", async () => {
  let searchedPrompt = "";
  const verifiedDomains = [];
  const provider = createLiveWebShopProvider({
    search: async prompt => {
      searchedPrompt = prompt;
      return { candidates: [{ url: "https://shop.example/a" }, { url: "https://shop.example/a?ref=home" }] };
    },
    verify: async (_url, domains) => {
      verifiedDomains.push(domains);
      return { canonicalURL: "https://shop.example/a", id: "a" };
    }
  });
  const products = await provider.discoverVerifiedProducts({ query: "layering top", domains: ["shop.example"] });
  assert.equal(provider.id, "live-web");
  assert.equal(products.length, 1);
  assert.match(searchedPrompt, /only these retailer domains: shop\.example/i);
  assert.match(searchedPrompt, /untrusted data/i);
  assert.match(searchedPrompt, /only women's clothing/i);
  assert.doesNotMatch(searchedPrompt, /owned wardrobe|style profile/i);
  assert.deepEqual(verifiedDomains, [["shop.example"], ["shop.example"]]);
});

test("web discovery deterministically keeps only the selected audience", async () => {
  const provider = createLiveWebShopProvider({
    search: async () => ({ candidates: [{ url: "https://shop.example/mens-shirt" }, { url: "https://shop.example/womens-shirt" }] }),
    verify: async url => url.includes("mens-") && !url.includes("womens-")
      ? { id: "mens", canonicalURL: url, title: "Men's Shirt" }
      : { id: "women", canonicalURL: url, title: "Women's Shirt" }
  });
  const products = await provider.discoverVerifiedProducts({ query: "shirt", domains: ["shop.example"], preferences: { clothingAudience: "men" } });
  assert.deepEqual(products.map(item => item.id), ["mens"]);
});
