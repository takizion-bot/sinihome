// Per-request Supabase client for API routes.
// The browser already owns the user's session; we forward the JWT via the
// Authorization header so SECURITY DEFINER RPCs still see auth.uid().
// Payment confirmation, refunds and webhooks use getAdminSupabase(): those RPCs
// are service_role only, and the server verifies every payment with Toss first.

import { createClient, type SupabaseClient } from '@supabase/supabase-js';

const url = process.env.NEXT_PUBLIC_SUPABASE_URL!;
const anonKey = process.env.NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY!;

/** Client that carries the caller's user JWT. Use for customer-initiated actions. */
export function getUserSupabase(authHeader: string | null | undefined): SupabaseClient {
  const token = authHeader?.replace(/^Bearer\s+/i, '').trim();
  return createClient(url, anonKey, {
    auth: { persistSession: false, autoRefreshToken: false },
    global: token ? { headers: { Authorization: `Bearer ${token}` } } : undefined,
  });
}

/** Anon client with no user context. Not used for anything that records money. */
export function getAnonSupabase(): SupabaseClient {
  return createClient(url, anonKey, {
    auth: { persistSession: false, autoRefreshToken: false },
  });
}

/** Server-only privileged client for trusted webhook work. Never import in client components. */
export function getAdminSupabase(): SupabaseClient {
  const serviceRoleKey = process.env.SUPABASE_SERVICE_ROLE_KEY;
  if (!serviceRoleKey) throw new Error('SUPABASE_SERVICE_ROLE_KEY is not configured');

  return createClient(url, serviceRoleKey, {
    auth: { persistSession: false, autoRefreshToken: false },
  });
}
