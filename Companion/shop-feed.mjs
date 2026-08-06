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

export function deduplicateShopProducts(products) {
  const ids = new Set(); const urls = new Set(); const merchantTitles = new Set(); const result = [];
  for (const item of products) {
    const id = String(item?.sourceProductID || item?.id || "").toLowerCase();
    let url = String(item?.canonicalURL || "").toLowerCase();
    try {
      const parsed = new URL(url); parsed.hash = "";
      for (const key of [...parsed.searchParams.keys()]) if (key.startsWith("utm_") || ["_gsid", "ref", "source"].includes(key)) parsed.searchParams.delete(key);
      url = parsed.href;
    } catch { /* malformed URLs are rejected by providers */ }
    const title = String(item?.title || "").toLowerCase().replace(/[^a-z0-9]+/g, " ").trim();
    const merchantTitle = `${String(item?.domain || "").toLowerCase()}:${title}`;
    if ((id && ids.has(id)) || (url && urls.has(url)) || (title && merchantTitles.has(merchantTitle))) continue;
    if (id) ids.add(id); if (url) urls.add(url); if (title) merchantTitles.add(merchantTitle);
    result.push(item);
  }
  return result;
}

export function appendRetailerDiverseProducts(published, wave, limit = 60, perPage = 2, perFeed = 4) {
  const ids = new Set(published.map(item => item.id));
  const feedCounts = new Map(); const pageCounts = new Map();
  const pageStart = Math.floor(published.length / 12) * 12;
  for (const [index, item] of published.entries()) {
    const domain = String(item.domain || "unknown");
    feedCounts.set(domain, (feedCounts.get(domain) || 0) + 1);
    if (index >= pageStart) pageCounts.set(domain, (pageCounts.get(domain) || 0) + 1);
  }
  for (const item of wave) {
    if (published.length >= limit) break;
    const domain = String(item.domain || "unknown");
    if (ids.has(item.id) || (feedCounts.get(domain) || 0) >= perFeed || (pageCounts.get(domain) || 0) >= perPage) continue;
    ids.add(item.id); published.push(item);
    feedCounts.set(domain, (feedCounts.get(domain) || 0) + 1);
    pageCounts.set(domain, (pageCounts.get(domain) || 0) + 1);
    if (published.length % 12 === 0) pageCounts.clear();
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
  const explicitCategory = String(product?.category || "").trim().toLowerCase();
  if (["tops", "bottoms", "outerwear", "dresses", "shoes", "accessories"].includes(explicitCategory)) return explicitCategory;
  const text = [product?.category, product?.subcategory, product?.title, product?.label, product?.description, product?.details].filter(Boolean).join(" ").toLowerCase();
  if (/\b(?:shoe|shoes|boot|boots|loafer|loafers|sneaker|sneakers|heel|heels|sandal|sandals|flat|flats)\b/.test(text)) return "shoes";
  if (/\b(?:pant|pants|trouser|trousers|jean|jeans|skirt|skirts|short|shorts|capri|capris|legging|leggings)\b/.test(text)) return "bottoms";
  if (/\b(?:coat|jacket|cardigan|blazer|outerwear|cover[- ]?up)\b/.test(text)) return "outerwear";
  if (/\b(?:dress|dresses|jumpsuit|romper)\b/.test(text)) return "dresses";
  if (/\b(?:top|tops|shirt|blouse|tee|t-shirt|tank|camisole|bodysuit|turtleneck|sweater)\b/.test(text)) return "tops";
  if (/\b(?:hat|cap|scarf|belt|bag|tights|sock|socks|leg warmer|jewelry|necklace|accessor)\b/.test(text)) return "accessories";
  return null;
}

export function inspirationRequestedRole(query) {
  const text = String(query || "").toLowerCase();
  if (/\b(?:tops only|similar tops|find purchasable tops)\b/.test(text)) return "tops";
  if (/\b(?:bottoms only|similar bottoms|find purchasable bottoms)\b/.test(text)) return "bottoms";
  return null;
}

export function focusedInspirationSearchBrief(examples, focusIDs, requestedRole = null) {
  const focused = new Set((focusIDs || []).map(String));
  const matches = (examples || []).filter(item => focused.has(String(item?.id)));
  const values = (key, limit) => [...new Set(matches.flatMap(item => item?.[key] || [])
    .map(String).map(value => value.trim()).filter(Boolean))].slice(0, limit);
  const parts = [
    requestedRole ? `${requestedRole} only` : "individual garments visible in the outfit",
    ...values("outfitFormula", 3), ...values("silhouettes", 4), ...values("palette", 4),
    ...values("details", 5), ...values("proportions", 3), ...values("layering", 2)
  ];
  return [...new Set(parts)].join(", ").slice(0, 420);
}

export function passesFocusedInspirationMatch(selection, focusIDs) {
  const focused = new Set((focusIDs || []).map(String));
  const matched = (selection?.matchedInspirationIDs || []).map(String);
  return matched.some(id => focused.has(id)) &&
    Number(selection?.confidence) >= 0.72 && Number(selection?.tasteFit) >= 0.76 &&
    Number(selection?.silhouetteFit) >= 0.72 && Number(selection?.colorFit) >= 0.68 &&
    Number(selection?.constructionFit) >= 0.60;
}

export function focusedOutfitRoleState(wardrobe, focusGarmentIDs) {
  const focus = new Set((focusGarmentIDs || []).map(String));
  const occupied = new Set(
    (wardrobe || []).filter(item => focus.has(String(item.id))).map(productRole).filter(Boolean)
  );
  let missingFoundation = null;
  if (occupied.has("tops") && !occupied.has("bottoms") && !occupied.has("dresses")) missingFoundation = "bottoms";
  else if (occupied.has("bottoms") && !occupied.has("tops") && !occupied.has("dresses")) missingFoundation = "tops";
  return { occupied, missingFoundation };
}

export function canCompleteFocusedOutfit(product, wardrobe, focusGarmentIDs) {
  const { occupied } = focusedOutfitRoleState(wardrobe, focusGarmentIDs);
  const role = productRole(product);
  if (!role) return true;
  if (role === "dresses" && ["tops", "bottoms", "dresses"].some(value => occupied.has(value))) return false;
  if (occupied.has("dresses") && ["tops", "bottoms"].includes(role)) return false;
  // Saved categories are the source of truth. An outfit search complements its
  // existing pieces; it never silently replaces a filled clothing slot.
  if (["tops", "bottoms", "shoes", "dresses", "outerwear"].includes(role) && occupied.has(role)) return false;
  return true;
}

export function appendFocusedComplements(published, wave, wardrobe, focusGarmentIDs, limit = 6) {
  const ids = new Set(published.map(item => item.id));
  const addedRoles = new Set(published.map(productRole).filter(Boolean));
  const { missingFoundation } = focusedOutfitRoleState(wardrobe, focusGarmentIDs);
  const ordered = [...wave].sort((left, right) =>
    Number(productRole(right) === missingFoundation) - Number(productRole(left) === missingFoundation)
  );
  for (const item of ordered) {
    if (published.length >= limit) break;
    const role = productRole(item);
    if (ids.has(item.id) || !canCompleteFocusedOutfit(item, wardrobe, focusGarmentIDs)) continue;
    if (["tops", "bottoms", "outerwear", "dresses", "shoes"].includes(role) && addedRoles.has(role)) continue;
    ids.add(item.id); if (role) addedRoles.add(role); published.push(item);
  }
  return published;
}
