// GET /api/payments/toss/success?paymentKey=...&orderId=...&amount=...
// Toss redirects the customer here after they authenticate payment in the widget.
// We approve ("confirm") the payment server-side, record it, then redirect to a
// plain page. Doing the work in a redirecting route keeps refresh/back safe.

import { NextRequest, NextResponse } from 'next/server';
import { confirmAndRecord } from '@/lib/payments';

export const runtime = 'nodejs';
export const dynamic = 'force-dynamic';

function redirectTo(req: NextRequest, path: string) {
  const base = (process.env.NEXT_PUBLIC_BASE_URL || req.nextUrl.origin).replace(/\/+$/, '');
  return NextResponse.redirect(`${base}${path}`, 303);
}

export async function GET(req: NextRequest) {
  const params = req.nextUrl.searchParams;
  const paymentKey = params.get('paymentKey');
  const orderId = params.get('orderId');
  const amount = Number(params.get('amount'));

  if (!paymentKey || !orderId || !Number.isInteger(amount) || amount < 0) {
    return redirectTo(req, '/book/cancelled?code=INVALID_REQUEST');
  }

  const result = await confirmAndRecord({ paymentKey, orderId, amount });

  if (result.ok) {
    return result.kind === 'reschedule_fee'
      ? redirectTo(req, '/profile?reschedule=success')
      : redirectTo(req, `/book/success?order_id=${encodeURIComponent(orderId)}`);
  }

  if (result.kind === 'reschedule_fee') {
    return redirectTo(req, '/profile?reschedule=cancelled');
  }
  const q = new URLSearchParams({ code: result.code, message: result.message });
  return redirectTo(req, `/book/cancelled?${q.toString()}`);
}
