// Server-only Toss Payments API client (https://docs.tosspayments.com/reference).
// Auth is HTTP Basic with the secret key as username and an empty password.
// Never import this from a client component.

const API_BASE = 'https://api.tosspayments.com';

export class TossError extends Error {
  constructor(
    public code: string,
    message: string,
    public status: number,
  ) {
    super(message);
    this.name = 'TossError';
  }
}

export type TossCancel = {
  transactionKey: string;
  cancelAmount: number;
  cancelReason: string;
  canceledAt: string;
};

export type TossPayment = {
  paymentKey: string;
  orderId: string;
  orderName: string;
  status: 'READY' | 'IN_PROGRESS' | 'WAITING_FOR_DEPOSIT' | 'DONE' | 'CANCELED' | 'PARTIAL_CANCELED' | 'ABORTED' | 'EXPIRED';
  currency: string;
  totalAmount: number;
  balanceAmount: number;
  method: string | null;
  approvedAt: string | null;
  receipt?: { url?: string } | null;
  cancels?: TossCancel[] | null;
  failure?: { code?: string; message?: string } | null;
};

function authHeader(): string {
  const key = process.env.TOSS_SECRET_KEY;
  if (!key) throw new Error('TOSS_SECRET_KEY is not configured');
  return 'Basic ' + Buffer.from(`${key}:`).toString('base64');
}

async function tossRequest<T>(path: string, init?: { method?: 'GET' | 'POST'; body?: unknown; idempotencyKey?: string }): Promise<T> {
  const res = await fetch(`${API_BASE}${path}`, {
    method: init?.method ?? 'GET',
    headers: {
      Authorization: authHeader(),
      'Content-Type': 'application/json',
      ...(init?.idempotencyKey ? { 'Idempotency-Key': init.idempotencyKey } : {}),
    },
    body: init?.body ? JSON.stringify(init.body) : undefined,
    cache: 'no-store',
  });
  const json = (await res.json().catch(() => ({}))) as { code?: string; message?: string };
  if (!res.ok) {
    throw new TossError(json.code ?? 'UNKNOWN', json.message ?? 'Toss request failed', res.status);
  }
  return json as T;
}

/** Approves a payment after the customer authenticated in the widget. Must be called within 10 minutes. */
export function confirmPayment(paymentKey: string, orderId: string, amount: number) {
  return tossRequest<TossPayment>('/v1/payments/confirm', {
    method: 'POST',
    body: { paymentKey, orderId, amount },
  });
}

/** Source of truth for a payment's state (used to verify webhooks). */
export function getPayment(paymentKey: string) {
  return tossRequest<TossPayment>(`/v1/payments/${encodeURIComponent(paymentKey)}`);
}

/** Full cancel when `amount` is omitted, partial otherwise. */
export function cancelPayment(
  paymentKey: string,
  opts: { reason: string; amount?: number; idempotencyKey: string },
) {
  return tossRequest<TossPayment>(`/v1/payments/${encodeURIComponent(paymentKey)}/cancel`, {
    method: 'POST',
    body: { cancelReason: opts.reason, ...(opts.amount ? { cancelAmount: opts.amount } : {}) },
    idempotencyKey: opts.idempotencyKey,
  });
}
