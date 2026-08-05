import assert from "node:assert/strict";
import test from "node:test";
import { isPrivateAddress, normalizeDomain, parseProductHTML } from "../shop-discovery.mjs";

test("retailer domains normalize without accepting arbitrary URL schemes or IPs", () => {
  assert.equal(normalizeDomain("https://www.aritzia.com/us/en"), "aritzia.com");
  assert.equal(normalizeDomain(" cantoncollective.com "), "cantoncollective.com");
  assert.equal(normalizeDomain("http://example.com"), null);
  assert.equal(normalizeDomain("127.0.0.1"), null);
});

test("private and local addresses are rejected", () => {
  for (const value of ["127.0.0.1", "10.0.0.2", "100.64.0.1", "172.16.2.3", "192.168.1.1", "169.254.1.2", "198.51.100.2", "203.0.113.4", "::1", "fd00::1", "2001:db8::1", "ff02::1"]) assert.equal(isPrivateAddress(value), true);
  assert.equal(isPrivateAddress("8.8.8.8"), false);
  assert.equal(isPrivateAddress("2606:4700:4700::1111"), false);
});

test("JSON-LD products produce verified canonical metadata and markdowns", () => {
  const html = `
    <html><head>
      <link rel="canonical" href="/products/lace-top">
      <meta property="og:site_name" content="Example Shop">
      <script type="application/ld+json">{
        "@context":"https://schema.org","@type":"Product","name":"Sheer Lace Top","image":["https://cdn.example.com/lace.jpg"],
        "color":["Black","Ivory"],"category":"Tops","description":"A fitted lace layering top.",
        "offers":{"@type":"Offer","price":"39.00","priceCurrency":"USD","priceSpecification":{"price":"59.00"}}
      }</script>
    </head></html>`;
  const product = parseProductHTML(html, new URL("https://shop.example.com/products/lace-top?ref=home"));
  assert.equal(product.title, "Sheer Lace Top");
  assert.equal(product.canonicalURL, "https://shop.example.com/products/lace-top");
  assert.equal(product.currentPrice, 39);
  assert.equal(product.originalPrice, 59);
  assert.equal(product.currency, "USD");
  assert.deepEqual(product.colors, ["Black", "Ivory"]);
  assert.equal(product.category, "tops");
});

test("Open Graph fallback works but missing images are rejected", () => {
  const html = `<meta property="og:title" content="Wide Leg Pants"><meta property="og:url" content="/pants"><meta property="og:image" content="/pants.jpg"><meta property="product:price:amount" content="49.90"><meta property="product:price:currency" content="USD">`;
  const product = parseProductHTML(html, "https://example.com/pants");
  assert.equal(product.category, "bottoms");
  assert.equal(product.imageURL, "https://example.com/pants.jpg");
  assert.throws(() => parseProductHTML(`<meta property="og:title" content="No image">`, "https://example.com/no-image"));
  assert.throws(() => parseProductHTML(`<meta property="og:title" content="No canonical"><meta property="og:image" content="/image.jpg">`, "https://example.com/no-canonical"));
});
