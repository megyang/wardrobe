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

export function shoppingAudience(preferences) {
  const value = String(preferences?.clothingAudience || "women").toLowerCase();
  return ["women", "unisex", "men"].includes(value) ? value : "women";
}

export function shoppingAudienceLabel(preferences) {
  return { women: "women's", unisex: "unisex", men: "men's" }[shoppingAudience(preferences)];
}

export function audienceConstrainedQuery(query, preferences) {
  const value = String(query || "").trim();
  return `${shoppingAudienceLabel(preferences)} clothing: ${value}`;
}

export function allowsShoppingAudience(product, preferences) {
  const text = [product?.title, product?.description, product?.canonicalURL, ...(product?.tags || [])]
    .filter(Boolean).join(" ").toLowerCase();
  const womens = /\b(?:women|woman|womens|women['’]s|female|ladies)\b/.test(text);
  const mens = /\b(?:men|man|mens|men['’]s|male|menswear)\b/.test(text) ||
    /(?:^|[\/_-])mens?(?:[\/_-]|$)/.test(text);
  const unisex = /\b(?:unisex|gender[- ]?neutral)\b/.test(text) || (womens && mens);
  switch (shoppingAudience(preferences)) {
  case "unisex": return unisex;
  case "men": return !unisex && (!womens || mens);
  default: return !unisex && (!mens || womens);
  }
}

export function productRole(product) {
  const text = [product?.category, product?.subcategory, product?.title, product?.label, product?.description, product?.details].filter(Boolean).join(" ").toLowerCase();
  if (/\b(?:shoe|shoes|boot|boots|loafer|loafers|sneaker|sneakers|heel|heels|sandal|sandals|flat|flats)\b/.test(text)) return "shoes";
  if (/\b(?:pant|pants|trouser|trousers|jean|jeans|skirt|skirts|short|shorts|capri|capris|legging|leggings)\b/.test(text)) return "bottoms";
  if (/\b(?:coat|jacket|cardigan|blazer|outerwear|cover[- ]?up)\b/.test(text)) return "outerwear";
  if (/\b(?:dress|dresses|jumpsuit|romper)\b/.test(text)) return "dresses";
  if (/\b(?:top|tops|shirt|blouse|tee|t-shirt|tank|camisole|bodysuit|turtleneck|sweater)\b/.test(text)) return "tops";
  if (/\b(?:hat|cap|scarf|belt|bag|tights|sock|socks|leg warmer|jewelry|necklace|accessor)\b/.test(text)) return "accessories";
  return null;
}

export function canCompleteFocusedOutfit(product, wardrobe, focusGarmentIDs) {
  const focus = new Set((focusGarmentIDs || []).map(String));
  const occupied = new Set((wardrobe || []).filter(item => focus.has(String(item.id))).map(item => item.category));
  const role = productRole(product);
  if (!role) return true;
  if (["bottoms", "shoes", "dresses", "outerwear"].includes(role) && occupied.has(role)) return false;
  if (role === "tops" && occupied.has("tops")) {
    const text = [product?.category, product?.subcategory, product?.title, product?.label, product?.description, product?.details].filter(Boolean).join(" ").toLowerCase();
    return /\b(?:layer|layering|under|undershirt|camisole|tank|turtleneck|mesh|sheer|cardigan|vest)\b/.test(text);
  }
  return true;
}
