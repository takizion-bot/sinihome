// POST /api/checkout
// Creates a pending_payment booking (holds the slot for 30 min) together with a
// 'ready' payment row. No payment-provider call happens here: the browser opens
// the Toss payment widget with the returned orderId / amount, and Toss then
// redirects to /api/payments/toss/success, which approves and records it.

import { NextRequest, NextResponse } from 'next/server';
import { getUserSupabase } from '@/lib/supabase-server';
import { findPlanBySlug } from '@/lib/plans';

export const runtime = 'nodejs';

type CheckoutBody = {
  planSlug: string;
  locationId: string;
  date: string; // yyyy-MM-dd
  startMinutes: number;
  extraDurationMinutes: number;
  groupSize: number;
  addonIds: string[];
  retouchNotes?: string;
  clientName: string;
  clientEmail: string;
  clientPhone: string;
  clientCountry: string;
  specialRequests?: string;
  agreedToPolicy: boolean;
};

function errorResponse(message: string, status = 400) {
  return NextResponse.json({ error: message }, { status });
}

export async function POST(req: NextRequest) {
  let body: CheckoutBody;
  try {
    body = (await req.json()) as CheckoutBody;
  } catch {
    return errorResponse('Invalid JSON body');
  }

  const plan = findPlanBySlug(body.planSlug);
  if (!plan) return errorResponse('Unknown plan');
  if (!body.agreedToPolicy) return errorResponse('Cancellation policy must be agreed to');

  const supabase = getUserSupabase(req.headers.get('authorization'));

  const { data: userData, error: userErr } = await supabase.auth.getUser();
  if (userErr || !userData?.user) return errorResponse('Unauthenticated', 401);

  // Slug -> plan row id. All pricing is computed inside the RPC.
  const { data: planRow, error: planErr } = await supabase
    .from('plans')
    .select('id')
    .eq('slug', plan.slug)
    .maybeSingle();
  if (planErr || !planRow) return errorResponse('Plan lookup failed', 500);

  const { data, error: rpcErr } = await supabase.rpc('create_pending_booking', {
    p_plan_id: planRow.id,
    p_location_id: body.locationId,
    p_date: body.date,
    p_start_minutes: body.startMinutes,
    p_extra_duration_minutes: body.extraDurationMinutes ?? 0,
    p_group_size: body.groupSize,
    p_retouch_notes: body.retouchNotes ?? '',
    p_addon_ids: body.addonIds ?? [],
    p_client_name: body.clientName,
    p_client_email: body.clientEmail,
    p_client_phone: body.clientPhone,
    p_client_country: body.clientCountry,
    p_special_requests: body.specialRequests ?? '',
    p_agreed_to_policy: body.agreedToPolicy,
  });
  if (rpcErr) {
    const msg = rpcErr.message || 'Failed to create booking';
    if (msg.includes('NO_AVAILABILITY')) return errorResponse('Sorry — that slot is no longer available. Please pick a different time.', 409);
    if (msg.includes('INVALID_')) return errorResponse('Invalid booking details.', 400);
    if (msg.includes('POLICY_NOT_AGREED')) return errorResponse('You must agree to the cancellation policy.', 400);
    if (msg.includes('NOT_AUTHENTICATED')) return errorResponse('Unauthenticated', 401);
    return errorResponse(msg, 500);
  }

  const booking = data as {
    id: string;
    reference: string;
    order_id: string;
    order_name: string;
    amount: number;
  } | null;
  if (!booking) return errorResponse('Booking not returned', 500);

  return NextResponse.json({
    bookingId: booking.id,
    reference: booking.reference,
    orderId: booking.order_id,
    orderName: booking.order_name,
    amount: booking.amount,
  });
}
