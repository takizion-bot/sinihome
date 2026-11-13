'use client';

// Toss Payments widget (결제위젯) in a modal. The server has already created the
// order (orderId / amount come from /api/checkout, /api/checkout/resume or the
// reschedule endpoint). On "Pay", Toss takes the customer through
// authentication and then redirects to /api/payments/toss/success, where the
// server approves and records the payment.

import { useEffect, useRef, useState } from 'react';
import { loadTossPayments, type TossPaymentsWidgets } from '@tosspayments/tosspayments-sdk';
import { formatKRW } from '@/lib/format';

export type TossOrder = {
  orderId: string;
  orderName: string;
  amount: number;
};

type Props = {
  order: TossOrder;
  /** Stable, non-guessable id of the signed-in user (Supabase user id). */
  customerKey: string;
  customerEmail?: string;
  customerName?: string;
  customerMobilePhone?: string;
  onClose: () => void;
};

const CLIENT_KEY = process.env.NEXT_PUBLIC_TOSS_CLIENT_KEY;

export function TossPaymentModal({ order, customerKey, customerEmail, customerName, customerMobilePhone, onClose }: Props) {
  const widgetsRef = useRef<TossPaymentsWidgets | null>(null);
  const [ready, setReady] = useState(false);
  const [paying, setPaying] = useState(false);
  const [error, setError] = useState<string | null>(null);

  useEffect(() => {
    let cancelled = false;
    (async () => {
      if (!CLIENT_KEY) {
        setError('Payment is not configured (missing NEXT_PUBLIC_TOSS_CLIENT_KEY).');
        return;
      }
      try {
        const tossPayments = await loadTossPayments(CLIENT_KEY);
        const widgets = tossPayments.widgets({ customerKey });
        await widgets.setAmount({ currency: 'KRW', value: order.amount });
        await Promise.all([
          widgets.renderPaymentMethods({ selector: '#toss-payment-method', variantKey: 'DEFAULT' }),
          widgets.renderAgreement({ selector: '#toss-agreement', variantKey: 'AGREEMENT' }),
        ]);
        if (cancelled) return;
        widgetsRef.current = widgets;
        setReady(true);
      } catch (e) {
        if (!cancelled) setError(e instanceof Error ? e.message : 'Could not load the payment window.');
      }
    })();
    return () => {
      cancelled = true;
    };
  }, [customerKey, order.amount]);

  useEffect(() => {
    const onKey = (e: KeyboardEvent) => {
      if (e.key === 'Escape' && !paying) onClose();
    };
    window.addEventListener('keydown', onKey);
    return () => window.removeEventListener('keydown', onKey);
  }, [onClose, paying]);

  const handlePay = async () => {
    const widgets = widgetsRef.current;
    if (!widgets || paying) return;
    setPaying(true);
    setError(null);
    try {
      await widgets.requestPayment({
        orderId: order.orderId,
        orderName: order.orderName,
        successUrl: `${window.location.origin}/api/payments/toss/success`,
        failUrl: `${window.location.origin}/api/payments/toss/fail`,
        customerEmail: customerEmail || undefined,
        customerName: customerName || undefined,
        customerMobilePhone: customerMobilePhone?.replace(/[^0-9]/g, '') || undefined,
      });
      // On success the browser is redirected away; nothing else to do here.
    } catch (e) {
      // Thrown when the customer closes the window or validation fails.
      const err = e as { code?: string; message?: string };
      if (err.code !== 'USER_CANCEL') setError(err.message ?? 'Payment could not be started.');
      setPaying(false);
    }
  };

  return (
    <div
      className="fixed inset-0 z-[100] flex items-end sm:items-center justify-center bg-black/50 p-0 sm:p-4"
      role="dialog"
      aria-modal="true"
      aria-label="Payment"
    >
      <div className="relative w-full sm:max-w-lg max-h-[95vh] overflow-y-auto bg-white rounded-t-2xl sm:rounded-2xl shadow-xl">
        <div className="sticky top-0 z-10 flex items-center justify-between gap-4 bg-white px-5 pt-5 pb-3 border-b border-black/5">
          <div>
            <div className="text-xs text-gray-500 font-medium">{order.orderName}</div>
            <div className="text-xl font-semibold text-black">{formatKRW(order.amount)}</div>
          </div>
          <button
            type="button"
            onClick={onClose}
            disabled={paying}
            aria-label="Close payment window"
            className="mobile-touch-target w-9 h-9 rounded-full text-black/60 hover:bg-black/5 disabled:opacity-40"
          >
            ✕
          </button>
        </div>

        <div className="px-2 py-2">
          <div id="toss-payment-method" />
          <div id="toss-agreement" />
        </div>

        {error && <p className="px-5 pb-2 text-sm text-red-600 font-medium">{error}</p>}

        <div className="sticky bottom-0 bg-white px-5 py-4 border-t border-black/5">
          <button
            type="button"
            onClick={handlePay}
            disabled={!ready || paying}
            className="mobile-touch-target w-full px-6 py-3 bg-black text-white rounded-lg text-sm font-medium hover:bg-black/80 disabled:opacity-50 transition-colors"
          >
            {paying ? 'Opening payment…' : ready ? `Pay ${formatKRW(order.amount)}` : 'Loading payment methods…'}
          </button>
          <p className="mt-2 text-center text-[11px] text-gray-400">
            Your slot is held for 30 minutes. Payments are processed securely by Toss Payments.
          </p>
        </div>
      </div>
    </div>
  );
}
