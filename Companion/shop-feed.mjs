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
