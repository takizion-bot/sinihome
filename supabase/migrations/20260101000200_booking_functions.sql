-- =====================================================================
-- Booking + payment functions.
--
-- Naming: functions starting with "_" are internal helpers (no API access).
-- Customer-facing RPCs run as the signed-in user (auth.uid()).
-- Anything that records money (mark_payment_done, refunds, webhooks) is
-- service_role ONLY: the Next.js server verifies with Toss first, then calls
-- it with SUPABASE_SERVICE_ROLE_KEY. (The old Stripe code let the anon key
-- mark bookings as paid - that hole is closed here.)
--
-- Error contract: functions raise exceptions whose message starts with an
-- upper-case code (NO_AVAILABILITY, FORBIDDEN, ...). API routes match on it.
-- =====================================================================

-- ---------------------------------------------------------------------
-- Availability
-- ---------------------------------------------------------------------

-- Can a shoot of p_duration minutes start at p_start on p_date at p_location?
-- p_exclude: a booking to ignore (the booking being rescheduled / resumed).
create function public._slot_is_free(
  p_date date,
  p_location_id uuid,
  p_start integer,
  p_duration integer,
  p_exclude uuid default null
)
returns boolean
language plpgsql
stable
set search_path = ''
as $$
declare
  s public.app_settings;
  v_hours public.location_hours;
  v_end integer := p_start + p_duration;
  v_overlap integer;
begin
  select * into s from public.app_settings;

  select * into v_hours
  from public.location_hours
  where location_id = p_location_id
    and weekday = extract(dow from p_date)::int;
  if not found then return false; end if;                       -- closed that day

  if p_start < v_hours.open_minutes or v_end > v_hours.close_minutes then return false; end if;
  if (p_start - v_hours.open_minutes) % s.slot_step_minutes <> 0 then return false; end if;

  if exists (
    select 1 from public.blocked_dates d
    where d.date = p_date and (d.location_id is null or d.location_id = p_location_id)
  ) then return false; end if;

  -- Photographers are shared across locations, so overlaps (plus travel
  -- buffer) are counted studio-wide. Live holds count, expired holds do not.
  select count(*) into v_overlap
  from public.bookings b
  where b.date = p_date
    and b.status <> 'cancelled'
    and (b.status <> 'pending_payment' or b.hold_expires_at > now())
    and (p_exclude is null or b.id <> p_exclude)
    and b.start_minutes - s.buffer_minutes < v_end
    and b.end_minutes   + s.buffer_minutes > p_start;

  return v_overlap < s.max_concurrent_bookings;
end;
$$;

create function public._available_slots(
  p_date date,
  p_location_id uuid,
  p_duration integer,
  p_exclude uuid default null
)
returns setof text
language plpgsql
stable
set search_path = ''
as $$
declare
  s public.app_settings;
  v_hours public.location_hours;
  v_start integer;
begin
  select * into s from public.app_settings;
  if p_date < public._today() + s.min_notice_days then return; end if;

  select * into v_hours
  from public.location_hours
  where location_id = p_location_id and weekday = extract(dow from p_date)::int;
  if not found then return; end if;

  for v_start in
    select g from generate_series(v_hours.open_minutes, v_hours.close_minutes - p_duration, s.slot_step_minutes) g
  loop
    if public._slot_is_free(p_date, p_location_id, v_start, p_duration, p_exclude) then
      return next lpad((v_start / 60)::text, 2, '0') || ':' || lpad((v_start % 60)::text, 2, '0');
    end if;
  end loop;
end;
$$;

-- Browser: free start times ("HH:MM") for a date / location / total minutes.
create function public.get_available_slots(
  p_date date,
  p_location_id uuid,
  p_plan_duration_minutes integer
)
returns setof text
language sql
stable
security definer
set search_path = ''
as $$
  select public._available_slots(p_date, p_location_id, p_plan_duration_minutes, null);
$$;

-- ---------------------------------------------------------------------
-- Policy (cancel / reschedule) - single source of truth
-- ---------------------------------------------------------------------
create function public._policy(p_b public.bookings)
returns jsonb
language plpgsql
stable
set search_path = ''
as $$
declare
  s public.app_settings;
  v_hours numeric;
  v_active boolean;
  v_pct integer;
  v_refund integer;
  v_fee integer;
begin
  select * into s from public.app_settings;
  v_hours := extract(epoch from (public._booking_start(p_b.date, p_b.start_minutes) - now())) / 3600;
  v_active := p_b.status in ('pending_confirmation', 'confirmed', 'pending_reschedule_confirmation')
              and v_hours > 0;

  v_pct := case
    when v_hours >= s.full_refund_hours then 100
    when v_hours >= s.partial_refund_hours then s.partial_refund_percent
    else 0
  end;
  v_refund := greatest(0, floor(p_b.total_price * v_pct / 100.0)::int - p_b.refund_amount);
  v_fee := ceil(p_b.total_price * s.reschedule_fee_percent / 100.0)::int;

  return jsonb_build_object(
    'booking_id', p_b.id,
    'status', p_b.status,
    'payment_status', p_b.payment_status,
    'hours_until_start', round(v_hours, 2),
    'total_price', p_b.total_price,
    'cancel_refund_percent', v_pct,
    'cancel_refund_amount', case when v_active then v_refund else 0 end,
    'can_cancel', v_active,
    'reschedule_fee_amount', v_fee,
    'can_reschedule_free', v_active and p_b.status <> 'pending_reschedule_confirmation'
                           and v_hours >= s.full_refund_hours,
    'can_reschedule_paid', v_active and p_b.status <> 'pending_reschedule_confirmation'
                           and v_hours >= s.partial_refund_hours and v_hours < s.full_refund_hours
  );
end;
$$;

-- Caller must own the booking (service_role bypasses).
create function public._owned_booking(p_booking_id uuid, p_lock boolean default false)
returns public.bookings
language plpgsql
set search_path = ''
as $$
declare
  b public.bookings;
begin
  if p_lock then
    select * into b from public.bookings where id = p_booking_id for update;
  else
    select * into b from public.bookings where id = p_booking_id;
  end if;
  if not found then raise exception 'BOOKING_NOT_FOUND'; end if;
  if auth.role() <> 'service_role' then
    if auth.uid() is null then raise exception 'NOT_AUTHENTICATED'; end if;
    if b.tourist_id is distinct from auth.uid() then raise exception 'FORBIDDEN'; end if;
  end if;
  return b;
end;
$$;

create function public.get_booking_policy(p_booking_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
begin
  return public._policy(public._owned_booking(p_booking_id));
end;
$$;

create function public.get_reschedule_slots(p_booking_id uuid, p_date date)
returns setof text
language plpgsql
security definer
set search_path = ''
as $$
declare
  b public.bookings := public._owned_booking(p_booking_id);
begin
  return query
    select public._available_slots(p_date, b.location_id, b.end_minutes - b.start_minutes, b.id);
end;
$$;

-- ---------------------------------------------------------------------
-- Creating a booking + its payment row
-- ---------------------------------------------------------------------
create function public._new_order_id(p_prefix text)
returns text
language sql
volatile
set search_path = ''
as $$
  select p_prefix || replace(gen_random_uuid()::text, '-', '');   -- 35 chars, Toss allows 6-64
$$;

-- Authoritative pricing + slot hold. Returns what the client needs to open
-- the Toss payment window (order_id, amount, order_name).
create function public.create_pending_booking(
  p_plan_id uuid,
  p_location_id uuid,
  p_date date,
  p_start_minutes integer,
  p_extra_duration_minutes integer,
  p_group_size integer,
  p_retouch_notes text,
  p_addon_ids uuid[],
  p_client_name text,
  p_client_email text,
  p_client_phone text,
  p_client_country text,
  p_special_requests text,
  p_agreed_to_policy boolean
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid uuid := auth.uid();
  s public.app_settings;
  v_plan public.plans;
  v_loc public.locations;
  v_extra integer := coalesce(p_extra_duration_minutes, 0);
  v_duration integer;
  v_addon_ids uuid[];
  v_addon_total integer;
  v_addon_count integer;
  v_total integer;
  v_booking public.bookings;
begin
  if v_uid is null then raise exception 'NOT_AUTHENTICATED'; end if;
  if not coalesce(p_agreed_to_policy, false) then raise exception 'POLICY_NOT_AGREED'; end if;

  select * into s from public.app_settings;
  select * into v_plan from public.plans where id = p_plan_id and is_active;
  if not found then raise exception 'INVALID_PLAN'; end if;
  select * into v_loc from public.locations where id = p_location_id and is_active;
  if not found then raise exception 'INVALID_LOCATION'; end if;

  if p_date is null or p_start_minutes is null then raise exception 'INVALID_DATE'; end if;
  if p_group_size is null or p_group_size < 1 or p_group_size > 10 then raise exception 'INVALID_GROUP_SIZE'; end if;
  if v_extra < 0 or v_extra > 180 or v_extra % 30 <> 0 then raise exception 'INVALID_EXTRA_DURATION'; end if;
  if length(btrim(coalesce(p_client_name, ''))) = 0
     or length(btrim(coalesce(p_client_phone, ''))) = 0
     or position('@' in coalesce(p_client_email, '')) < 2 then
    raise exception 'INVALID_CLIENT_DETAILS';
  end if;

  v_duration := v_plan.duration_minutes + v_extra;

  -- Serialise bookings for the same day so two people cannot take one slot.
  perform pg_advisory_xact_lock(hashtext('booking-day:' || p_date::text));

  if p_date < public._today() + s.min_notice_days then raise exception 'INVALID_DATE'; end if;
  if not public._slot_is_free(p_date, p_location_id, p_start_minutes, v_duration, null) then
    raise exception 'NO_AVAILABILITY';
  end if;

  select coalesce(array_agg(distinct x), '{}') into v_addon_ids from unnest(coalesce(p_addon_ids, '{}')) x;
  select coalesce(sum(price), 0), count(*) into v_addon_total, v_addon_count
  from public.addons where id = any(v_addon_ids) and is_active;
  if v_addon_count <> cardinality(v_addon_ids) then raise exception 'INVALID_ADDON'; end if;

  v_total := v_plan.price
           + v_loc.surcharge
           + (v_extra / 30) * s.extra_time_price_per_30min
           + greatest(p_group_size - 1, 0) * v_plan.extra_person_price
           + v_addon_total;

  insert into public.bookings (
    reference, tourist_id, plan_id, location_id, date, start_minutes, end_minutes,
    extra_duration_minutes, group_size, client_name, client_email, client_phone,
    client_country, special_requests, retouch_notes, agreed_to_policy,
    status, payment_status, total_price, hold_expires_at
  ) values (
    public._new_booking_reference(), v_uid, p_plan_id, p_location_id, p_date, p_start_minutes,
    p_start_minutes + v_duration, v_extra, p_group_size, btrim(p_client_name),
    lower(btrim(p_client_email)), btrim(p_client_phone), btrim(coalesce(p_client_country, '')),
    coalesce(p_special_requests, ''), coalesce(p_retouch_notes, ''), true,
    'pending_payment', 'pending', v_total, now() + make_interval(mins => s.hold_minutes)
  ) returning * into v_booking;

  insert into public.booking_addons (booking_id, addon_id, price_snapshot)
  select v_booking.id, a.id, a.price from public.addons a where a.id = any(v_addon_ids);

  return public._start_booking_payment(v_booking, v_plan.name);
end;
$$;

-- Creates a 'ready' payment for a pending booking and returns the Toss params.
create function public._start_booking_payment(p_b public.bookings, p_plan_name text)
returns jsonb
language plpgsql
set search_path = ''
as $$
declare
  s public.app_settings;
  v_payment public.payments;
begin
  select * into s from public.app_settings;
  insert into public.payments (booking_id, kind, order_id, order_name, amount, expires_at)
  values (
    p_b.id, 'booking', public._new_order_id('bk_'),
    left('@ Studio ON - ' || p_plan_name, 100),
    p_b.total_price, now() + make_interval(mins => s.hold_minutes)
  ) returning * into v_payment;

  return jsonb_build_object(
    'id', p_b.id,
    'reference', p_b.reference,
    'total_price', p_b.total_price,
    'date', p_b.date,
    'start_minutes', p_b.start_minutes,
    'order_id', v_payment.order_id,
    'order_name', v_payment.order_name,
    'amount', v_payment.amount
  );
end;
$$;

-- Re-open payment for a booking whose Toss window was abandoned / expired.
create function public.resume_pending_payment(p_booking_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  s public.app_settings;
  b public.bookings := public._owned_booking(p_booking_id, true);
  v_plan_name text;
begin
  select * into s from public.app_settings;
  if b.status <> 'pending_payment' then raise exception 'BOOKING_NOT_RESUMABLE'; end if;
  if b.date < public._today() then raise exception 'BOOKING_DATE_PASSED'; end if;

  perform pg_advisory_xact_lock(hashtext('booking-day:' || b.date::text));
  if not public._slot_is_free(b.date, b.location_id, b.start_minutes, b.end_minutes - b.start_minutes, b.id) then
    raise exception 'SLOT_NO_LONGER_AVAILABLE';
  end if;

  update public.payments set status = 'expired'
  where booking_id = b.id and kind = 'booking' and status = 'ready';

  update public.bookings
  set hold_expires_at = now() + make_interval(mins => s.hold_minutes), payment_status = 'pending'
  where id = b.id
  returning * into b;

  select name into v_plan_name from public.plans where id = b.plan_id;
  return public._start_booking_payment(b, v_plan_name);
end;
$$;

-- Customer abandons an unpaid booking: free the slot.
create function public.cancel_pending_payment(p_booking_id uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  b public.bookings := public._owned_booking(p_booking_id, true);
begin
  if b.status <> 'pending_payment' then raise exception 'BOOKING_NOT_CANCELLABLE'; end if;
  update public.bookings
  set status = 'cancelled', cancelled_at = now(), cancelled_reason = 'customer_cancelled_unpaid'
  where id = b.id;
  update public.payments set status = 'expired' where booking_id = b.id and status = 'ready';
end;
$$;

-- Releases expired slot holds. Idempotent; the UI calls it on profile load and
-- availability already ignores expired holds, so a scheduler is optional.
create function public.sweep_expired_pending_bookings()
returns integer
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_count integer;
begin
  update public.bookings
  set status = 'cancelled', cancelled_at = now(), cancelled_reason = 'payment_hold_expired'
  where status = 'pending_payment' and hold_expires_at < now();
  get diagnostics v_count = row_count;

  update public.payments set status = 'expired' where status = 'ready' and expires_at < now();
  return v_count;
end;
$$;

-- ---------------------------------------------------------------------
-- Rescheduling
-- ---------------------------------------------------------------------
create function public.apply_free_reschedule(
  p_booking_id uuid,
  p_new_date date,
  p_new_start_minutes integer
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  s public.app_settings;
  b public.bookings := public._owned_booking(p_booking_id, true);
begin
  select * into s from public.app_settings;
  if not coalesce((public._policy(b) ->> 'can_reschedule_free')::boolean, false) then
    raise exception 'FREE_RESCHEDULE_WINDOW_CLOSED';
  end if;

  perform pg_advisory_xact_lock(hashtext('booking-day:' || p_new_date::text));
  if p_new_date < public._today() + s.min_notice_days
     or not public._slot_is_free(p_new_date, b.location_id, p_new_start_minutes, b.end_minutes - b.start_minutes, b.id) then
    raise exception 'NO_AVAILABILITY';
  end if;

  update public.bookings
  set date = p_new_date,
      start_minutes = p_new_start_minutes,
      end_minutes = p_new_start_minutes + (b.end_minutes - b.start_minutes),
      reschedule_count = reschedule_count + 1
  where id = b.id
  returning * into b;
  return to_jsonb(b);
end;
$$;

-- Paid reschedule (24-48h window): validates the new slot and creates the
-- fee payment. The new slot is applied by mark_payment_done once paid.
create function public.stash_pending_reschedule(
  p_booking_id uuid,
  p_new_date date,
  p_new_start_minutes integer
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  s public.app_settings;
  b public.bookings := public._owned_booking(p_booking_id, true);
  v_policy jsonb;
  v_payment public.payments;
begin
  select * into s from public.app_settings;
  v_policy := public._policy(b);
  if not coalesce((v_policy ->> 'can_reschedule_paid')::boolean, false) then
    raise exception 'PAID_RESCHEDULE_NOT_AVAILABLE';
  end if;

  perform pg_advisory_xact_lock(hashtext('booking-day:' || p_new_date::text));
  if p_new_date < public._today() + s.min_notice_days
     or not public._slot_is_free(p_new_date, b.location_id, p_new_start_minutes, b.end_minutes - b.start_minutes, b.id) then
    raise exception 'NO_AVAILABILITY';
  end if;

  update public.payments set status = 'expired'
  where booking_id = b.id and kind = 'reschedule_fee' and status = 'ready';

  insert into public.payments (
    booking_id, kind, order_id, order_name, amount, expires_at,
    pending_reschedule_date, pending_reschedule_start_minutes
  ) values (
    b.id, 'reschedule_fee', public._new_order_id('rs_'),
    left('Rescheduling Fee - ' || b.reference, 100),
    (v_policy ->> 'reschedule_fee_amount')::int,
    now() + make_interval(mins => s.hold_minutes),
    p_new_date, p_new_start_minutes
  ) returning * into v_payment;

  return jsonb_build_object(
    'order_id', v_payment.order_id,
    'order_name', v_payment.order_name,
    'amount', v_payment.amount
  );
end;
$$;

-- ---------------------------------------------------------------------
-- Money in (service_role only)
-- ---------------------------------------------------------------------

-- Called after the server has confirmed the payment with Toss.
-- Idempotent: safe to call from the success page AND the webhook.
create function public.mark_payment_done(
  p_order_id text,
  p_payment_key text,
  p_amount integer,
  p_method text default null,
  p_receipt_url text default null,
  p_approved_at timestamptz default null,
  p_raw jsonb default null
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  p public.payments;
  b public.bookings;
  v_dur integer;
begin
  select * into p from public.payments where order_id = p_order_id for update;
  if not found then raise exception 'PAYMENT_NOT_FOUND'; end if;
  if p.amount <> p_amount then raise exception 'AMOUNT_MISMATCH'; end if;

  if p.status = 'done' then
    return jsonb_build_object('kind', p.kind, 'booking_id', p.booking_id, 'already_done', true);
  end if;

  update public.payments
  set status = 'done', payment_key = p_payment_key, method = p_method, receipt_url = p_receipt_url,
      approved_at = coalesce(p_approved_at, now()), raw = p_raw,
      failure_code = null, failure_message = null
  where id = p.id;

  select * into b from public.bookings where id = p.booking_id for update;
  v_dur := b.end_minutes - b.start_minutes;
  perform pg_advisory_xact_lock(hashtext('booking-day:' || b.date::text));

  if p.kind = 'booking' then
    if b.status = 'pending_payment' then
      update public.bookings
      set status = 'pending_confirmation', payment_status = 'paid', paid_at = now(), hold_expires_at = null
      where id = b.id;
    elsif b.status = 'cancelled' and b.cancelled_reason = 'payment_hold_expired' then
      -- Paid after the hold was swept: revive only if the slot is still free.
      if b.date >= public._today()
         and public._slot_is_free(b.date, b.location_id, b.start_minutes, v_dur, b.id) then
        update public.bookings
        set status = 'pending_confirmation', payment_status = 'paid', paid_at = now(),
            hold_expires_at = null, cancelled_at = null, cancelled_reason = null
        where id = b.id;
      else
        update public.payments set apply_error = 'SLOT_TAKEN_AFTER_HOLD_EXPIRED - refund required' where id = p.id;
      end if;
    end if;
  else
    -- reschedule_fee
    if b.status in ('pending_confirmation', 'confirmed', 'pending_reschedule_confirmation')
       and public._slot_is_free(p.pending_reschedule_date, b.location_id, p.pending_reschedule_start_minutes, v_dur, b.id) then
      update public.bookings
      set date = p.pending_reschedule_date,
          start_minutes = p.pending_reschedule_start_minutes,
          end_minutes = p.pending_reschedule_start_minutes + v_dur,
          reschedule_count = reschedule_count + 1
      where id = b.id;
    else
      update public.payments set apply_error = 'RESCHEDULE_NOT_APPLIED - refund or fix manually' where id = p.id;
    end if;
  end if;

  return jsonb_build_object('kind', p.kind, 'booking_id', p.booking_id, 'already_done', false);
end;
$$;

-- Payment attempt failed (Toss error / window closed) or the window expired.
create function public.mark_payment_failed(
  p_order_id text,
  p_code text default null,
  p_message text default null,
  p_expired boolean default false
)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  p public.payments;
begin
  select * into p from public.payments where order_id = p_order_id for update;
  if not found or p.status not in ('ready', 'failed') then return; end if;   -- never touch a 'done' payment

  update public.payments
  set status = case when p_expired then 'expired' else 'failed' end,
      failure_code = p_code, failure_message = p_message
  where id = p.id;

  -- Slot hold stays until it lapses so the customer can retry via resume.
  if p.kind = 'booking' and not p_expired then
    update public.bookings set payment_status = 'failed'
    where id = p.booking_id and status = 'pending_payment';
  end if;
end;
$$;

-- ---------------------------------------------------------------------
-- Money out (service_role only)
-- ---------------------------------------------------------------------

-- After Toss accepted the refund for a customer-initiated cancellation.
-- p_refund_amount = 0 is allowed (no refund due under the policy).
create function public.apply_booking_cancellation(
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
  v_refunded integer;
begin
  select * into b from public.bookings where id = p_booking_id for update;
  if not found then raise exception 'BOOKING_NOT_FOUND'; end if;
  if b.status in ('cancelled', 'completed', 'pending_payment') then
    raise exception 'BOOKING_NOT_CANCELLABLE';
  end if;

  if coalesce(p_refund_amount, 0) > 0 and p_transaction_key is not null then
    select * into p from public.payments
    where booking_id = b.id and kind = 'booking' and status in ('done', 'partial_canceled')
    order by created_at desc limit 1;
    if found then
      insert into public.payment_refunds (payment_id, transaction_key, amount, reason)
      values (p.id, p_transaction_key, p_refund_amount, 'customer_cancellation')
      on conflict (transaction_key) do nothing;
    end if;
  end if;

  v_refunded := b.refund_amount + coalesce(p_refund_amount, 0);

  update public.bookings
  set status = 'cancelled',
      cancelled_at = now(),
      cancelled_reason = 'customer_cancelled',
      refund_amount = v_refunded,
      refunded_at = case when coalesce(p_refund_amount, 0) > 0 then now() else refunded_at end,
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

-- Webhook: Toss reports a cancel (also covers refunds made in the Toss
-- dashboard). Idempotent via transaction_key.
create function public.record_payment_cancellation(
  p_payment_key text,
  p_transaction_key text,
  p_amount integer,
  p_reason text default null,
  p_canceled_at timestamptz default null
)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  p public.payments;
  v_total integer;
begin
  select * into p from public.payments where payment_key = p_payment_key for update;
  if not found then raise exception 'PAYMENT_NOT_FOUND'; end if;

  insert into public.payment_refunds (payment_id, transaction_key, amount, reason, canceled_at)
  values (p.id, p_transaction_key, p_amount, p_reason, coalesce(p_canceled_at, now()))
  on conflict (transaction_key) do nothing;

  select coalesce(sum(amount), 0) into v_total from public.payment_refunds where payment_id = p.id;
  update public.payments
  set status = case when v_total >= p.amount then 'canceled' else 'partial_canceled' end
  where id = p.id;

  if p.kind = 'booking' then
    update public.bookings
    set refund_amount = v_total,
        refunded_at = now(),
        payment_status = case when v_total >= total_price then 'refunded' else 'partially_refunded' end
    where id = p.booking_id;
  end if;
end;
$$;

-- ---------------------------------------------------------------------
-- Webhook idempotency + success-page lookup (service_role only)
-- ---------------------------------------------------------------------

-- true  = first time we see this event (process it)
-- false = duplicate delivery (skip)
create function public.record_payment_event(p_event_key text, p_event_type text)
returns boolean
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_rows integer;
begin
  insert into public.payment_webhook_events (event_key, event_type)
  values (p_event_key, p_event_type)
  on conflict (event_key) do nothing;
  get diagnostics v_rows = row_count;
  return v_rows > 0;
end;
$$;

create function public.get_booking_by_order(p_order_id text)
returns table (
  booking_id uuid, reference text, client_name text, status text,
  payment_status text, kind text, payment_status_detail text
)
language sql
stable
security definer
set search_path = ''
as $$
  select b.id, b.reference, b.client_name, b.status, b.payment_status, p.kind, p.status
  from public.payments p
  join public.bookings b on b.id = p.booking_id
  where p.order_id = p_order_id;
$$;
