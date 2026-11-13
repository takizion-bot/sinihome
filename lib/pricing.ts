// Single source of truth for booking price composition (display side).
// Mirrors the SQL in public.create_pending_booking so the review screen matches
// what Toss will charge. The server ALWAYS recomputes before charging.
// All amounts are whole KRW.

import type { Plan } from './plans';
import type { Location, Addon } from './data';

/** Must equal app_settings.extra_time_price_per_30min in the database. */
export const EXTRA_TIME_PRICE_PER_30MIN = 139000;

export type PricingInput = {
  plan: Pick<Plan, 'price' | 'extraPersonPrice'>;
  location: Pick<Location, 'surcharge'>;
  extraDurationMinutes: number;
  groupSize: number;
  addons: Pick<Addon, 'price'>[];
};

export type PricingBreakdown = {
  base: number;
  location: number;
  extraTime: number;
  extraPeople: number;
  addons: number;
  total: number;
};

export function extraTimePrice(extraDurationMinutes: number): number {
  return Math.floor(extraDurationMinutes / 30) * EXTRA_TIME_PRICE_PER_30MIN;
}

export function computePricing(input: PricingInput): PricingBreakdown {
  const base = input.plan.price;
  const location = input.location.surcharge;
  const extraTime = extraTimePrice(input.extraDurationMinutes);
  const extraPeople = input.groupSize > 1 ? (input.groupSize - 1) * input.plan.extraPersonPrice : 0;
  const addons = input.addons.reduce((s, a) => s + a.price, 0);
  return { base, location, extraTime, extraPeople, addons, total: base + location + extraTime + extraPeople + addons };
}
