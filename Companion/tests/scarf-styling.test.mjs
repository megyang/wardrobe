import test from "node:test";
import assert from "node:assert/strict";
import { ensureScarfStylingRationale } from "../scarf-styling.mjs";

const wardrobe = [
  { id: "top", category: "tops", subcategory: "t_shirt", label: "White tee" },
  { id: "scarf", category: "accessories", subcategory: "scarf", label: "Long floral scarf" }
];

test("leaves non-scarf outfit rationales unchanged", () => {
  const outfit = { garmentIDs: ["top"], rationale: "A clean foundation." };
  assert.equal(ensureScarfStylingRationale(outfit, wardrobe, "Simple and crisp."), "Simple and crisp.");
});

test("preserves two explicit final scarf alternatives", () => {
  const outfit = { garmentIDs: ["top", "scarf"], rationale: "Original." };
  const final = "The print adds focus. How to wear the scarf: tie it close at the neck with long trailing ends. Another way: wear the scarf as a ponytail ribbon.";
  assert.equal(ensureScarfStylingRationale(outfit, wardrobe, final), final);
});

test("restores the candidate scarf instruction when the critic drops it", () => {
  const outfit = {
    garmentIDs: ["top", "scarf"],
    rationale: "The colors connect. Wear the scarf as a loose neck drape."
  };
  assert.equal(
    ensureScarfStylingRationale(outfit, wardrobe, "The colors connect the pieces."),
    "The colors connect the pieces. Wear the scarf as a loose neck drape. Another way: use it as a ribbon around a low ponytail, leaving the ends loose."
  );
});

test("adds a clear fallback instruction when both model passes omit one", () => {
  const outfit = { garmentIDs: ["top", "scarf"], rationale: "The print adds interest." };
  assert.equal(
    ensureScarfStylingRationale(outfit, wardrobe, "The palette feels cohesive."),
    "The palette feels cohesive. How to wear the scarf: knot the Long floral scarf loosely at the neck and leave the ends long. Another way: use it as a ribbon around a low ponytail, leaving the ends loose."
  );
});

test("a description that only copies the uploaded pose is replaced with alternatives", () => {
  const outfit = { garmentIDs: ["top", "scarf"], rationale: "Wear the scarf as pictured." };
  const result = ensureScarfStylingRationale(outfit, wardrobe, "Wear the scarf as shown.");
  assert.match(result, /How to wear the scarf:/);
  assert.match(result, /Another way:/);
});

test("mentioning a scarf near a bag is not mistaken for wearing guidance", () => {
  const outfit = { garmentIDs: ["top", "scarf"], rationale: "The scarf balances the bag." };
  assert.match(
    ensureScarfStylingRationale(outfit, wardrobe, "The scarf balances the bag."),
    /How to wear the scarf:/
  );
});
