// Hardcoded source of truth for customer-facing plans.
// Prices are whole KRW and MUST match public.plans in the database (seeded in
// supabase/migrations). The server recomputes every total from the DB before
// charging via Toss Payments, so these are display values only.

export type PlanSlug = 'quick' | 'portrait' | 'fisheye' | 'signature' | 'couple';

export type Plan = {
  slug: PlanSlug;
  name: string;
  price: number;
  originalPrice: number;
  // Price per additional person beyond the first. 0 means extra people are
  // included at no charge (e.g. the Couple / Proposal package).
  extraPersonPrice: number;
  duration: number;
  description: string;
  tagline: string;
  lens: string;
  photoCount: string;
};

export const PLANS: Plan[] = [
  {
    slug: 'quick',
    name: 'Tokyo Quick Shot',
    price: 99000,
    originalPrice: 125000,
    extraPersonPrice: 69000,
    duration: 30,
    tagline: '30 minutes, portrait lens',
    description: 'A 30-minute portrait session capturing natural, candid moments across 2–3 iconic Tokyo locations.',
    lens: 'Portrait Lens Only',
    photoCount: '20 Edited Photos',
  },
  {
    slug: 'portrait',
    name: 'Full Portrait Session',
    price: 139000,
    originalPrice: 179000,
    extraPersonPrice: 77000,
    duration: 50,
    tagline: '50 minutes, portrait lens',
    description: 'A 50-minute portrait session capturing natural, candid moments across 4–5 iconic Tokyo locations.',
    lens: 'Portrait Lens Only',
    photoCount: '35 Edited Photos',
  },
  {
    slug: 'fisheye',
    name: 'Fish Eye Session',
    price: 209000,
    originalPrice: 265000,
    extraPersonPrice: 84000,
    duration: 50,
    tagline: '50 minutes, signature fish-eye',
    description: 'A 50-minute creative session with our signature fish-eye lens for bold, wide-angle shots.',
    lens: 'Fish Eye Lens Only',
    photoCount: '50 Edited Photos',
  },
  {
    slug: 'signature',
    name: 'Signature Session',
    price: 265000,
    originalPrice: 335000,
    extraPersonPrice: 91000,
    duration: 50,
    tagline: '50 minutes, both lenses',
    description: 'A 50-minute session combining both lenses for a full range of cinematic shots.',
    lens: 'Portrait + Fish Eye Lens',
    photoCount: '60 Edited Photos',
  },
  {
    slug: 'couple',
    name: 'Couple / Proposal Session',
    price: 419000,
    originalPrice: 529000,
    extraPersonPrice: 0,
    duration: 50,
    tagline: '50 minutes, couple story',
    description: 'A 50-minute couples shoot with both lenses, capturing your Tokyo story together.',
    lens: 'Portrait + Fish Eye Lens',
    photoCount: '70 Edited Photos',
  },
];

export function findPlanBySlug(slug: string): Plan | null {
  return PLANS.find((p) => p.slug === slug) ?? null;
}
