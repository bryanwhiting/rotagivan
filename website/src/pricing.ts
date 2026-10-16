// Edit these to set the public Voice mode price shown on the site.
// The amount actually charged comes from the Stripe Price configured as
// STRIPE_PRICE_ID_VOICE in wrangler.jsonc — keep the two in sync.
export const voicePrice = {
  amount: "$—", // e.g. "$4"
  period: "per month", // e.g. "per month", "one-time"
  note: "Price to be announced.",
};
