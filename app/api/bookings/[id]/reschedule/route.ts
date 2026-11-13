// POST /api/bookings/[id]/reschedule
// Customer self-service rescheduling. Two paths:
//   1. Within the free window (>48h) — applied directly.
//   2. Within the paid window (24–48h) — the RPC validates the new slot and
//      creates a 'ready' fee payment; the browser then opens the Toss widget.
//      The new date/time is applied by the server once the fee is approved.
// Outside those windows (<24h) the server rejects.

import { NextRequest, NextResponse } from 'next/server';
import { getUserSupabase } from '@/lib/supabase-server';

export const runtime = 'nodejs';

type Body = {
  newDate: string;
  newStartMinutes: number;
};

export async function POST(
  req: NextRequest,
  { params }: { params: Promise<{ id: string }> },
) {
  const { id } = await params;
  let body: Body;
  try {
    body = (await req.json()) as Body;
  } catch {
    return NextResponse.json({ error: 'Invalid JSON body' }, { status: 400 });
  }

  const supabase = getUserSupabase(req.headers.get('authorization'));
  const { data: userData } = await supabase.auth.getUser();
  if (!userData?.user) return NextResponse.json({ error: 'Unauthenticated' }, { status: 401 });

  const { data: policyData, error: policyErr } = await supabase.rpc('get_booking_policy', { p_booking_id: id });
  if (policyErr) {
    const status = policyErr.message.includes('FORBIDDEN') ? 403 : policyErr.message.includes('BOOKING_NOT_FOUND') ? 404 : 400;
    return NextResponse.json({ error: policyErr.message }, { status });
  }
  const policy = Array.isArray(policyData) ? policyData[0] : policyData;
  if (!policy) return NextResponse.json({ error: 'Policy unavailable' }, { status: 404 });

  if (policy.can_reschedule_free) {
    const { data, error } = await supabase.rpc('apply_free_reschedule', {
      p_booking_id: id,
      p_new_date: body.newDate,
      p_new_start_minutes: body.newStartMinutes,
    });
    if (error) {
      const msg = error.message;
      if (msg.includes('NO_AVAILABILITY')) return NextResponse.json({ error: 'That new slot is unavailable. Please pick another.' }, { status: 409 });
      if (msg.includes('FREE_RESCHEDULE_WINDOW_CLOSED')) return NextResponse.json({ error: 'Free reschedule window has closed.' }, { status: 409 });
      return NextResponse.json({ error: msg }, { status: 400 });
    }
    return NextResponse.json({ mode: 'free', booking: data });
  }

  if (policy.can_reschedule_paid) {
    const { data, error } = await supabase.rpc('stash_pending_reschedule', {
      p_booking_id: id,
      p_new_date: body.newDate,
      p_new_start_minutes: body.newStartMinutes,
    });
    if (error) {
      const msg = error.message;
      if (msg.includes('NO_AVAILABILITY')) return NextResponse.json({ error: 'That new slot is unavailable. Please pick another.' }, { status: 409 });
      if (msg.includes('PAID_RESCHEDULE_NOT_AVAILABLE')) return NextResponse.json({ error: 'Rescheduling is not possible at this time.' }, { status: 409 });
      console.error('[reschedule] stash_pending_reschedule failed', msg);
      return NextResponse.json({ error: msg }, { status: 500 });
    }
    const fee = data as { order_id: string; order_name: string; amount: number };
    return NextResponse.json({
      mode: 'paid',
      feeAmount: fee.amount,
      orderId: fee.order_id,
      orderName: fee.order_name,
      amount: fee.amount,
    });
  }

  return NextResponse.json({ error: 'Rescheduling is not possible within 24 hours of the shoot.' }, { status: 409 });
}
