// Server-only: turns a Toss redirect (paymentKey, orderId, amount) into a
// recorded payment. Shared by the success redirect route and the webhook path.
//
// Safety rules:
//  - The amount is compared with OUR database row before Toss is called, so a
//    tampered successUrl cannot approve a different price.
//  - Everything is idempotent: refreshing the success URL or receiving the
//    webhook as well will not double-process.

import { getAdminSupabase } from '@/lib/supabase-server';
import { confirmPayment, getPayment, TossError, type TossPayment } from '@/lib/toss';
import { sendBookingNotifications } from '@/lib/booking-email';

export type PaymentKind = 'booking' | 'reschedule_fee';

export type ConfirmResult =
  | { ok: true; kind: PaymentKind; bookingId: string }
  | { ok: false; kind: PaymentKind | null; code: string; message: string };

type PaymentRow = { id: string; booking_id: string; kind: PaymentKind; amount: number; status: string };

/** Records an already-approved Toss payment (status DONE) in the database. */
export async function recordApprovedPayment(payment: TossPayment): Promise<{ kind: PaymentKind; bookingId: string; alreadyDone: boolean }> {
  const supabase = getAdminSupabase();
  const { data, error } = await supabase.rpc('mark_payment_done', {
    p_order_id: payment.orderId,
    p_payment_key: payment.paymentKey,
    p_amount: payment.totalAmount,
    p_method: payment.method,
    p_receipt_url: payment.receipt?.url ?? null,
    p_approved_at: payment.approvedAt,
    p_raw: payment,
  });
  if (error) {
    // Money has been taken but we could not record it: make this loud.
    console.error('[payments] mark_payment_done FAILED after Toss approval', payment.orderId, error.message);
    throw new Error(error.message);
  }
  const result = data as { kind: PaymentKind; booking_id: string; already_done: boolean };

  if (result.kind === 'booking') {
    try {
      await sendBookingNotifications(result.booking_id);
    } catch (err) {
      // Payment is authoritative; e-mail delivery is retryable (idempotent).
      console.error('[payments] booking notifications failed', err);
    }
  }
  return { kind: result.kind, bookingId: result.booking_id, alreadyDone: result.already_done };
}

export async function confirmAndRecord(input: { paymentKey: string; orderId: string; amount: number }): Promise<ConfirmResult> {
  const supabase = getAdminSupabase();

  const { data: row } = await supabase
    .from('payments')
    .select('id, booking_id, kind, amount, status')
    .eq('order_id', input.orderId)
    .maybeSingle<PaymentRow>();
  if (!row) return { ok: false, kind: null, code: 'PAYMENT_NOT_FOUND', message: 'Unknown order.' };

  if (row.amount !== input.amount) {
    console.error('[payments] amount mismatch', input.orderId, 'db', row.amount, 'url', input.amount);
    return { ok: false, kind: row.kind, code: 'AMOUNT_MISMATCH', message: 'Payment amount does not match the order.' };
  }
  if (row.status === 'done') return { ok: true, kind: row.kind, bookingId: row.booking_id };

  let payment: TossPayment;
  try {
    payment = await confirmPayment(input.paymentKey, input.orderId, input.amount);
  } catch (err) {
    if (err instanceof TossError && err.code === 'ALREADY_PROCESSED_PAYMENT') {
      // e.g. the webhook or a refresh beat us to it - read the real state.
      try {
        payment = await getPayment(input.paymentKey);
      } catch {
        return { ok: false, kind: row.kind, code: err.code, message: err.message };
      }
    } else {
      const code = err instanceof TossError ? err.code : 'CONFIRM_FAILED';
      const message = err instanceof Error ? err.message : 'Payment confirmation failed.';
      console.error('[payments] Toss confirm failed', input.orderId, code, message);
      await supabase.rpc('mark_payment_failed', { p_order_id: input.orderId, p_code: code, p_message: message, p_expired: false });
      return { ok: false, kind: row.kind, code, message };
    }
  }

  if (payment.status !== 'DONE' || payment.totalAmount !== row.amount || payment.orderId !== input.orderId) {
    return { ok: false, kind: row.kind, code: 'NOT_APPROVED', message: `Payment is ${payment.status}.` };
  }

  try {
    const recorded = await recordApprovedPayment(payment);
    return { ok: true, kind: recorded.kind, bookingId: recorded.bookingId };
  } catch (err) {
    return {
      ok: false,
      kind: row.kind,
      code: 'RECORD_FAILED',
      message: err instanceof Error ? err.message : 'Could not record payment.',
    };
  }
}
