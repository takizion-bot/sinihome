// GET /api/payments/toss/fail?code=...&message=...&orderId=...
// Toss redirects here when the customer closes the widget or the payment is
// rejected. We record the outcome and send them to the right screen.

import { NextRequest, NextResponse } from 'next/server';
import { getAdminSupabase } from '@/lib/supabase-server';

export const runtime = 'nodejs';
export const dynamic = 'force-dynamic';

// Customer simply closed the payment window - not an error worth flagging.
const USER_CANCEL_CODES = new Set(['PAY_PROCESS_CANCELED', 'USER_CANCEL']);

export async function GET(req: NextRequest) {
  const params = req.nextUrl.searchParams;
  const code = params.get('code') ?? 'UNKNOWN';
  const message = params.get('message') ?? '';
  const orderId = params.get('orderId');
  const base = (process.env.NEXT_PUBLIC_BASE_URL || req.nextUrl.origin).replace(/\/+$/, '');

  let kind: string | null = null;
  if (orderId) {
    const supabase = getAdminSupabase();
    const { data } = await supabase.from('payments').select('kind').eq('order_id', orderId).maybeSingle();
    kind = data?.kind ?? null;
    // Never downgrades a payment that already succeeded (the RPC ignores 'done').
    await supabase.rpc('mark_payment_failed', {
      p_order_id: orderId,
      p_code: code,
      p_message: message,
      p_expired: USER_CANCEL_CODES.has(code),
    });
  }

  if (kind === 'reschedule_fee') {
    return NextResponse.redirect(`${base}/profile?reschedule=cancelled`, 303);
  }
  const q = new URLSearchParams({ code, ...(message ? { message } : {}) });
  return NextResponse.redirect(`${base}/book/cancelled?${q.toString()}`, 303);
}
