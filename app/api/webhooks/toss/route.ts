// POST /api/webhooks/toss
// Toss -> server event receiver (register this URL in the Toss developer
// console: 웹훅 > PAYMENT_STATUS_CHANGED).
//
// Payment-status webhooks carry no signature, so the body is NEVER trusted:
// we only take the paymentKey from it and re-read the payment from the Toss API
// with our secret key. Toss retries until it gets HTTP 200.

import { NextRequest, NextResponse } from 'next/server';
import { getAdminSupabase } from '@/lib/supabase-server';
import { getPayment, TossError, type TossPayment } from '@/lib/toss';
import { recordApprovedPayment } from '@/lib/payments';

export const runtime = 'nodejs';
export const dynamic = 'force-dynamic';

type WebhookBody = {
  eventType?: string;
  createdAt?: string;
  data?: { paymentKey?: string; orderId?: string; status?: string };
};

export async function POST(req: NextRequest) {
  let body: WebhookBody;
  try {
    body = (await req.json()) as WebhookBody;
  } catch {
    return NextResponse.json({ error: 'Invalid JSON' }, { status: 400 });
  }

  if (body.eventType !== 'PAYMENT_STATUS_CHANGED') {
    return NextResponse.json({ received: true, ignored: body.eventType ?? null });
  }
  const paymentKey = body.data?.paymentKey;
  if (!paymentKey) return NextResponse.json({ error: 'Missing paymentKey' }, { status: 400 });

  let payment: TossPayment;
  try {
    payment = await getPayment(paymentKey);
  } catch (err) {
    if (err instanceof TossError && err.status === 404) {
      return NextResponse.json({ received: true, ignored: 'unknown payment' });
    }
    console.error('[toss webhook] could not verify payment', err);
    return NextResponse.json({ error: 'verification failed' }, { status: 500 });
  }

  const supabase = getAdminSupabase();
  const eventKey = `${payment.paymentKey}:${payment.status}:${body.createdAt ?? ''}:${payment.cancels?.length ?? 0}`;

  const { data: isNew, error: recordErr } = await supabase.rpc('record_payment_event', {
    p_event_key: eventKey,
    p_event_type: `${body.eventType}:${payment.status}`,
  });
  if (recordErr) {
    console.error('[toss webhook] record_payment_event failed', recordErr.message);
    return NextResponse.json({ error: 'event record failed' }, { status: 500 });
  }
  if (isNew === false) return NextResponse.json({ received: true, duplicate: true });

  try {
    await handlePayment(payment);
  } catch (err) {
    console.error(`[toss webhook] handler for ${payment.status} threw`, err);
    // Release the claim so Toss's retry is processed instead of skipped.
    await supabase.from('payment_webhook_events').delete().eq('event_key', eventKey);
    return NextResponse.json({ error: 'handler error' }, { status: 500 });
  }

  return NextResponse.json({ received: true });
}

async function handlePayment(payment: TossPayment) {
  const supabase = getAdminSupabase();

  switch (payment.status) {
    case 'DONE': {
      // Covers a missed success redirect (customer closed the tab after paying).
      try {
        await recordApprovedPayment(payment);
      } catch (err) {
        if (err instanceof Error && err.message.includes('PAYMENT_NOT_FOUND')) return; // not one of ours
        throw err;
      }
      break;
    }
    case 'CANCELED':
    case 'PARTIAL_CANCELED': {
      // Also syncs refunds issued directly in the Toss dashboard.
      for (const c of payment.cancels ?? []) {
        const { error } = await supabase.rpc('record_payment_cancellation', {
          p_payment_key: payment.paymentKey,
          p_transaction_key: c.transactionKey,
          p_amount: c.cancelAmount,
          p_reason: c.cancelReason,
          p_canceled_at: c.canceledAt,
        });
        if (error && !error.message.includes('PAYMENT_NOT_FOUND')) throw new Error(error.message);
      }
      break;
    }
    case 'ABORTED':
    case 'EXPIRED': {
      const { error } = await supabase.rpc('mark_payment_failed', {
        p_order_id: payment.orderId,
        p_code: payment.failure?.code ?? payment.status,
        p_message: payment.failure?.message ?? null,
        p_expired: payment.status === 'EXPIRED',
      });
      if (error) throw new Error(error.message);
      break;
    }
    default:
      break;
  }
}
