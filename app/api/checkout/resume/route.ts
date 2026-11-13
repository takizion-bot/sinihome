// POST /api/checkout/resume
// Re-opens payment for an existing pending_payment booking: the RPC extends the
// slot hold and creates a fresh 'ready' payment (new Toss orderId). Used when
// the original payment window was abandoned or expired.

import { NextRequest, NextResponse } from 'next/server';
import { getUserSupabase } from '@/lib/supabase-server';

export const runtime = 'nodejs';

type ResumeBody = { bookingId: string };

function errorResponse(message: string, status = 400) {
  return NextResponse.json({ error: message }, { status });
}

export async function POST(req: NextRequest) {
  let body: ResumeBody;
  try {
    body = (await req.json()) as ResumeBody;
  } catch {
    return errorResponse('Invalid JSON body');
  }
  if (!body.bookingId) return errorResponse('Missing bookingId');

  const supabase = getUserSupabase(req.headers.get('authorization'));
  const { data: userData, error: userErr } = await supabase.auth.getUser();
  if (userErr || !userData?.user) return errorResponse('Unauthenticated', 401);

  const { data, error: rpcErr } = await supabase.rpc('resume_pending_payment', {
    p_booking_id: body.bookingId,
  });
  if (rpcErr) {
    const msg = rpcErr.message || 'Could not resume payment';
    if (msg.includes('BOOKING_NOT_FOUND')) return errorResponse('Booking not found', 404);
    if (msg.includes('FORBIDDEN')) return errorResponse('Booking not found', 404);
    if (msg.includes('SLOT_NO_LONGER_AVAILABLE')) {
      return errorResponse('That time slot is no longer available. Please book a new session.', 409);
    }
    if (msg.includes('BOOKING_DATE_PASSED')) return errorResponse('This booking date has already passed.', 409);
    if (msg.includes('BOOKING_NOT_RESUMABLE')) return errorResponse('This booking is no longer awaiting payment.', 409);
    if (msg.includes('NOT_AUTHENTICATED')) return errorResponse('Unauthenticated', 401);
    console.error('[resume] resume_pending_payment failed', msg);
    return errorResponse(msg, 500);
  }

  const booking = data as { id: string; reference: string; order_id: string; order_name: string; amount: number };
  return NextResponse.json({
    bookingId: booking.id,
    reference: booking.reference,
    orderId: booking.order_id,
    orderName: booking.order_name,
    amount: booking.amount,
  });
}
