// POST /api/bookings/[id]/cancel
// Customer-initiated cancellation. The refund amount comes from the policy RPC
// (never from the client). Order of operations: refund through Toss first, then
// mark the booking cancelled. If the DB step fails after the refund, the Toss
// webhook (PAYMENT_STATUS_CHANGED -> CANCELED) still syncs the refund amount, so
// no money is stranded.

import { NextRequest, NextResponse } from 'next/server';
import { getAdminSupabase, getUserSupabase } from '@/lib/supabase-server';
import { cancelPayment, TossError } from '@/lib/toss';

export const runtime = 'nodejs';

export async function POST(
  req: NextRequest,
  { params }: { params: Promise<{ id: string }> },
) {
  const { id } = await params;
  const supabase = getUserSupabase(req.headers.get('authorization'));

  const { data: userData } = await supabase.auth.getUser();
  if (!userData?.user) return NextResponse.json({ error: 'Unauthenticated' }, { status: 401 });

  // Ownership is enforced inside the RPC (FORBIDDEN / BOOKING_NOT_FOUND).
  const { data: policyData, error: policyErr } = await supabase.rpc('get_booking_policy', { p_booking_id: id });
  if (policyErr) {
    const status = policyErr.message.includes('FORBIDDEN') ? 403 : policyErr.message.includes('BOOKING_NOT_FOUND') ? 404 : 400;
    return NextResponse.json({ error: policyErr.message }, { status });
  }
  const policy = Array.isArray(policyData) ? policyData[0] : policyData;
  if (!policy) return NextResponse.json({ error: 'Policy unavailable' }, { status: 404 });
  if (!policy.can_cancel) return NextResponse.json({ error: 'Booking cannot be cancelled in its current state.' }, { status: 409 });

  const refundAmount: number = policy.cancel_refund_amount ?? 0;
  const admin = getAdminSupabase();

  let transactionKey: string | null = null;
  if (refundAmount > 0) {
    const { data: payment } = await admin
      .from('payments')
      .select('payment_key, amount')
      .eq('booking_id', id)
      .eq('kind', 'booking')
      .in('status', ['done', 'partial_canceled'])
      .order('created_at', { ascending: false })
      .limit(1)
      .maybeSingle();
    if (!payment?.payment_key) {
      return NextResponse.json({ error: 'No payment found for this booking.' }, { status: 409 });
    }

    try {
      const result = await cancelPayment(payment.payment_key, {
        reason: '고객 요청에 의한 예약 취소 (customer cancellation)',
        amount: refundAmount,
        // Same key on a retry => Toss returns the first result instead of refunding twice.
        idempotencyKey: `cancel-${id}-${refundAmount}`,
      });
      transactionKey = result.cancels?.[result.cancels.length - 1]?.transactionKey ?? null;
    } catch (err) {
      const msg = err instanceof TossError ? err.message : 'Refund failed';
      console.error('[cancel] Toss refund failed', err);
      return NextResponse.json({ error: msg }, { status: 502 });
    }
  }

  const { data: updated, error: applyErr } = await admin.rpc('apply_booking_cancellation', {
    p_booking_id: id,
    p_refund_amount: refundAmount,
    p_transaction_key: transactionKey,
  });
  if (applyErr) {
    console.error('[cancel] apply_booking_cancellation failed after refund', applyErr.message, 'tx', transactionKey);
    return NextResponse.json({ error: applyErr.message, transactionKey }, { status: 500 });
  }

  return NextResponse.json({ booking: updated, refundAmount, transactionKey });
}
