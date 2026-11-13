// Shared cancellation / reschedule policy — the canonical decisions live in
// public.get_booking_policy (SQL). These helpers only render preview messaging;
// final amounts always come from the server-authoritative RPC response.
// All amounts are whole KRW.

import { formatKRW } from './format';

export type PolicySnapshot = {
  hours_until_start: number;
  total_price: number;
  cancel_refund_percent: 0 | 50 | 100;
  cancel_refund_amount: number;
  can_cancel: boolean;
  reschedule_fee_amount: number;
  can_reschedule_free: boolean;
  can_reschedule_paid: boolean;
};

// UI copy for each policy bucket — keep concise and unambiguous.
export const CANCEL_POLICY_COPY: Record<number, string> = {
  100: '100% refund — more than 48 hours before the shoot.',
  50: '50% refund — between 24 and 48 hours before the shoot.',
  0: 'No refund — within 24 hours of the shoot.',
};

export const RESCHEDULE_POLICY_COPY: Record<number, string> = {
  0: 'Free reschedule — more than 48 hours before the shoot.',
  50: '50% fee to reschedule — between 24 and 48 hours before the shoot.',
  [-1]: 'Rescheduling is not possible within 24 hours of the shoot.',
};

export function formatRefundMessage(refundAmount: number): string {
  return `${formatKRW(refundAmount)} will be returned to the original payment method (card refunds typically take 3–7 business days).`;
}
