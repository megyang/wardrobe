export function retailerDiverse(products, limit = 60) {
  const buckets = new Map();
  for (const product of products) {
    if (!buckets.has(product.domain)) buckets.set(product.domain, []);
    buckets.get(product.domain).push(product);
  }
  const result = [];
  while (result.length < limit && [...buckets.values()].some(items => items.length)) {
    for (const items of buckets.values()) {
      if (items.length && result.length < limit) result.push(items.shift());
    }
  }
  return result;
}

export function appendStableProducts(published, wave, limit = 60) {
  const ids = new Set(published.map(item => item.id));
  for (const item of wave) {
    if (published.length >= limit) break;
    if (!ids.has(item.id)) { ids.add(item.id); published.push(item); }
  }
  return published;
}

export function shouldContinueShopFeed({ publishedCount, candidatesRemaining, lastWaveConfidence }) {
  if (publishedCount >= 60 || candidatesRemaining <= 0) return false;
  if (publishedCount < 40) return true;
  return publishedCount < 48 || lastWaveConfidence >= 0.55;
}

export function limitsToWomensAndUnisex(preferences) {
  return preferences?.womensAndUnisexOnly !== false;
}

export function audienceConstrainedQuery(query, preferences) {
  const value = String(query || "").trim();
  return limitsToWomensAndUnisex(preferences) ? `women's or unisex clothing: ${value}` : value;
}

export function allowsShoppingAudience(product, preferences) {
  if (!limitsToWomensAndUnisex(preferences)) return true;
  const text = [product?.title, product?.description, product?.canonicalURL, ...(product?.tags || [])]
    .filter(Boolean).join(" ").toLowerCase();
  const includesAllowedAudience = /\b(?:women|woman|womens|women's|female|ladies|unisex)\b/.test(text);
  const includesMensAudience = /\b(?:men|man|mens|men's|male|menswear)\b/.test(text) ||
    /(?:^|[\/_-])mens?(?:[\/_-]|$)/.test(text);
  return !includesMensAudience || includesAllowedAudience;
}
