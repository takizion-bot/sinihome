-- apply_booking_cancellation used to ADD the refund to bookings.refund_amount.
-- The Toss webhook (record_payment_cancellation) records the same refund too,
-- so whichever ran second double counted it. Both now derive refund_amount from
-- the payment_refunds ledger (unique per Toss transactionKey), so order and
-- retries no longer matter.

create or replace function public.apply_booking_cancellation(
  p_booking_id uuid,
  p_refund_amount integer,
  p_transaction_key text default null
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  b public.bookings;
  p public.payments;
  v_payment_id uuid;
  v_payment_amount integer;
  v_refunded integer;
begin
  select * into b from public.bookings where id = p_booking_id for update;
  if not found then raise exception 'BOOKING_NOT_FOUND'; end if;
  if b.status in ('cancelled', 'completed', 'pending_payment') then
    raise exception 'BOOKING_NOT_CANCELLABLE';
  end if;

  if coalesce(p_refund_amount, 0) > 0 then
    if p_transaction_key is null then raise exception 'TRANSACTION_KEY_REQUIRED'; end if;

    select * into p from public.payments
    where booking_id = b.id and kind = 'booking' and status in ('done', 'partial_canceled', 'canceled')
    order by created_at desc limit 1;
    if not found then raise exception 'PAYMENT_NOT_FOUND'; end if;
    v_payment_id := p.id;
    v_payment_amount := p.amount;

    insert into public.payment_refunds (payment_id, transaction_key, amount, reason)
    values (p.id, p_transaction_key, p_refund_amount, 'customer_cancellation')
    on conflict (transaction_key) do nothing;
  end if;

  select coalesce(sum(r.amount), 0) into v_refunded
  from public.payment_refunds r
  join public.payments pp on pp.id = r.payment_id
  where pp.booking_id = b.id and pp.kind = 'booking';

  if v_payment_id is not null then
    update public.payments
    set status = case
      when (select coalesce(sum(amount), 0) from public.payment_refunds where payment_id = v_payment_id) >= v_payment_amount
        then 'canceled' else 'partial_canceled' end
    where id = v_payment_id;
  end if;

  update public.bookings
  set status = 'cancelled',
      cancelled_at = now(),
      cancelled_reason = 'customer_cancelled',
      refund_amount = v_refunded,
      refunded_at = case when v_refunded > 0 then coalesce(refunded_at, now()) else refunded_at end,
      payment_status = case
        when v_refunded >= total_price and total_price > 0 then 'refunded'
        when v_refunded > 0 then 'partially_refunded'
        else payment_status
      end
  where id = b.id
  returning * into b;
  return to_jsonb(b);
end;
$$;

-- create or replace keeps existing grants, but state the intent explicitly.
revoke all on function public.apply_booking_cancellation(uuid, integer, text) from public, anon, authenticated;
grant execute on function public.apply_booking_cancellation(uuid, integer, text) to service_role;
