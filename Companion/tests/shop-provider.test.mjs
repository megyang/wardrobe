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
  assert.deepEqual(verifiedDomains, [["shop.example"], ["shop.example"]]);
});
