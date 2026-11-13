// Post-payment landing page. /api/payments/toss/success approves and records
// the payment, then redirects here with ?order_id=. This page only READS state
// (no side effects), so refreshing or sharing the URL is safe. If the payment
// is not recorded yet (e.g. the webhook is still on its way), it says so.

import type { Metadata } from 'next';
import Link from 'next/link';
import { Check } from 'lucide-react';
import { getAdminSupabase } from '@/lib/supabase-server';

export const runtime = 'nodejs';
export const dynamic = 'force-dynamic';

export const metadata: Metadata = {
  title: 'Booking Confirmed',
  description: 'Your @ Studio ON Tokyo photoshoot booking has been confirmed.',
  robots: { index: false, follow: false, nocache: true, googleBot: { index: false, follow: false } },
  alternates: { canonical: '/book/success' },
};

type Props = {
  searchParams: Promise<{ order_id?: string }>;
};

async function loadBooking(orderId: string): Promise<{ reference: string; name: string; error?: string }> {
  const supabase = getAdminSupabase();
  const { data: rows } = await supabase.rpc('get_booking_by_order', { p_order_id: orderId });
  const row = (rows as { reference: string; client_name: string; payment_status: string }[] | null)?.[0];

  if (!row) return { reference: '', name: '', error: 'Booking not found for this order.' };
  if (row.payment_status !== 'paid') {
    return {
      reference: row.reference,
      name: row.client_name,
      error: 'We have not received confirmation of your payment yet. Please check My Bookings in a minute; if you were charged, contact support.',
    };
  }
  return { reference: row.reference, name: row.client_name };
}

export default async function BookingSuccessPage({ searchParams }: Props) {
  const { order_id } = await searchParams;

  let reference = '';
  let name = '';
  let error: string | undefined;
  if (order_id) {
    try {
      const r = await loadBooking(order_id);
      reference = r.reference;
      name = r.name;
      error = r.error;
    } catch (e) {
      console.error('[success page]', e);
      error = 'We could not verify your booking. If you were charged, please contact support.';
    }
  } else {
    error = 'Missing order identifier.';
  }

  return (
    <main className="min-h-screen bg-[#fcfcfc] text-black pt-24 md:pt-32 pb-20 md:pb-24">
      <div className="w-full max-w-xl mx-auto px-4 md:px-6 text-center py-12">
        {error ? (
          <>
            <h1 className="text-3xl md:text-4xl font-medium tracking-tight mb-4">Something went wrong</h1>
            <p className="text-gray-500 font-medium max-w-md mx-auto mb-10">{error}</p>
            <Link
              href="/profile"
              className="px-10 py-4 border border-black/10 rounded-full font-medium text-black hover:bg-black/5 transition-colors inline-block"
            >
              View My Bookings
            </Link>
          </>
        ) : (
          <>
            <div className="w-24 h-24 bg-green-50 text-green-600 rounded-full flex items-center justify-center mx-auto mb-8">
              <Check size={48} />
            </div>
            <h1 className="text-3xl md:text-4xl font-medium tracking-tight mb-4">Booking Confirmed!</h1>
            <p className="text-gray-500 font-medium max-w-md mx-auto mb-10">
              Thank you{name ? `, ${name}` : ''}. Your payment was received. We&apos;ll contact you within 24 hours to confirm the details of your session.
            </p>
            <div className="p-8 bg-white border border-black/10 rounded-2xl inline-block mb-10 shadow-sm">
              <div className="text-sm text-gray-500 mb-2 font-medium">Booking Reference</div>
              <div className="text-3xl font-mono font-medium tracking-wider text-black">{reference}</div>
            </div>
            <div className="flex flex-col sm:flex-row gap-3 justify-center">
              <Link
                href="/profile"
                className="px-10 py-4 bg-black text-white rounded-full font-medium hover:bg-black/80 transition-colors inline-block"
              >
                View My Bookings
              </Link>
              <Link
                href="/"
                className="px-10 py-4 border border-black/10 rounded-full font-medium text-black hover:bg-black/5 transition-colors inline-block"
              >
                Return to Home
              </Link>
            </div>
          </>
        )}
      </div>
    </main>
  );
}
