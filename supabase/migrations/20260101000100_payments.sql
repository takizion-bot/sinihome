-- =====================================================================
-- Payments (Toss Payments)
--
-- Toss flow:
--   1. Server creates a row here (status 'ready') with our own order_id + amount.
--   2. Browser opens the Toss payment window with that orderId / amount.
--   3. Toss redirects to successUrl with paymentKey, orderId, amount.
--   4. Server calls Toss "confirm" API, then public.mark_payment_done(...).
--   5. Toss webhooks (PAYMENT_STATUS_CHANGED) keep refunds / failures in sync.
--
-- One row per payment attempt. A booking can have several (retries, the
-- reschedule fee, ...). Replaces the stripe_* columns on bookings.
-- =====================================================================

create table public.payments (
  id uuid primary key default gen_random_uuid(),
  booking_id uuid not null references public.bookings(id) on delete cascade,
  kind text not null check (kind in ('booking', 'reschedule_fee')),

  order_id text not null unique,            -- our id sent to Toss (6-64 chars)
  order_name text not null,
  amount integer not null check (amount >= 0),   -- KRW, verified against Toss on confirm

  status text not null default 'ready' check (status in (
    'ready', 'done', 'canceled', 'partial_canceled', 'failed', 'expired'
  )),
  payment_key text unique,                  -- Toss paymentKey (known after approval)
  method text,                              -- 카드, 간편결제, 계좌이체 ...
  receipt_url text,
  approved_at timestamptz,
  expires_at timestamptz,                   -- 'ready' rows are dead after this
  failure_code text,
  failure_message text,
  raw jsonb,                                -- Toss Payment object as returned by confirm

  -- kind = 'reschedule_fee': the new slot applied once the fee is paid
  pending_reschedule_date date,
  pending_reschedule_start_minutes integer,

  -- Set when money was taken but the booking could not be updated
  -- (e.g. the slot was taken meanwhile). Ops must refund or fix manually.
  apply_error text,

  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),

  check (kind <> 'reschedule_fee'
         or (pending_reschedule_date is not null and pending_reschedule_start_minutes is not null))
);
create index payments_booking_idx on public.payments (booking_id, created_at desc);
create index payments_ready_idx on public.payments (expires_at) where status = 'ready';
create trigger payments_updated_at before update on public.payments
  for each row execute function public.set_updated_at();

-- One row per cancel (refund) transaction reported by Toss.
create table public.payment_refunds (
  id uuid primary key default gen_random_uuid(),
  payment_id uuid not null references public.payments(id) on delete cascade,
  transaction_key text not null unique,     -- Toss cancels[].transactionKey (idempotency)
  amount integer not null check (amount > 0),
  reason text,
  canceled_at timestamptz not null default now(),
  created_at timestamptz not null default now()
);
create index payment_refunds_payment_idx on public.payment_refunds (payment_id);

-- Webhook idempotency: Toss retries deliveries, so every event is claimed once.
create table public.payment_webhook_events (
  event_key text primary key,
  event_type text not null,
  received_at timestamptz not null default now()
);
