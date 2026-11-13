-- =====================================================================
-- Row level security, grants, and reference data.
-- =====================================================================

-- ---------- RLS on everything ----------------------------------------
alter table public.app_settings enable row level security;
alter table public.members enable row level security;
alter table public.plans enable row level security;
alter table public.locations enable row level security;
alter table public.addons enable row level security;
alter table public.location_hours enable row level security;
alter table public.blocked_dates enable row level security;
alter table public.bookings enable row level security;
alter table public.booking_addons enable row level security;
alter table public.user_events enable row level security;
alter table public.payments enable row level security;
alter table public.payment_refunds enable row level security;
alter table public.payment_webhook_events enable row level security;

-- Public catalogue (read only).
create policy plans_read on public.plans for select to anon, authenticated using (true);
create policy locations_read on public.locations for select to anon, authenticated using (true);
create policy addons_read on public.addons for select to anon, authenticated using (true);
create policy location_hours_read on public.location_hours for select to anon, authenticated using (true);

-- Customers see only their own bookings. All writes go through RPCs.
create policy bookings_read_own on public.bookings
  for select to authenticated using (tourist_id = (select auth.uid()));

create policy booking_addons_read_own on public.booking_addons
  for select to authenticated using (
    exists (select 1 from public.bookings b
            where b.id = booking_addons.booking_id and b.tourist_id = (select auth.uid()))
  );

-- Analytics: a user may only log events for themselves.
create policy user_events_insert_own on public.user_events
  for insert to authenticated with check (tourist_id = (select auth.uid()));

-- app_settings, members, blocked_dates, payments, payment_refunds,
-- payment_webhook_events: no policies => reachable by service_role only.

-- ---------- table privileges ------------------------------------------
revoke all on all tables in schema public from anon, authenticated;
revoke all on all sequences in schema public from anon, authenticated;

grant select on public.plans, public.locations, public.addons, public.location_hours
  to anon, authenticated;
grant select on public.bookings, public.booking_addons to authenticated;
grant insert on public.user_events to authenticated;

grant all on all tables in schema public to service_role;
grant all on all sequences in schema public to service_role;

-- ---------- function privileges ---------------------------------------
-- Lock everything down, then open up exactly what each role needs.
revoke execute on all functions in schema public from public, anon, authenticated;
alter default privileges in schema public revoke execute on functions from public, anon, authenticated;

-- Browser / signed-in customer.
grant execute on function public.get_available_slots(date, uuid, integer) to anon, authenticated;
grant execute on function public.get_booking_policy(uuid) to authenticated;
grant execute on function public.get_reschedule_slots(uuid, date) to authenticated;
grant execute on function public.create_pending_booking(
  uuid, uuid, date, integer, integer, integer, text, uuid[], text, text, text, text, text, boolean
) to authenticated;
grant execute on function public.resume_pending_payment(uuid) to authenticated;
grant execute on function public.cancel_pending_payment(uuid) to authenticated;
grant execute on function public.sweep_expired_pending_bookings() to authenticated;
grant execute on function public.apply_free_reschedule(uuid, date, integer) to authenticated;
grant execute on function public.stash_pending_reschedule(uuid, date, integer) to authenticated;

-- Server only (Toss confirm / webhook / refunds).
grant execute on function public.mark_payment_done(text, text, integer, text, text, timestamptz, jsonb) to service_role;
grant execute on function public.mark_payment_failed(text, text, text, boolean) to service_role;
grant execute on function public.apply_booking_cancellation(uuid, integer, text) to service_role;
grant execute on function public.record_payment_cancellation(text, text, integer, text, timestamptz) to service_role;
grant execute on function public.record_payment_event(text, text) to service_role;
grant execute on function public.get_booking_by_order(text) to service_role;

-- service_role may call everything (including the helpers) when needed.
grant execute on all functions in schema public to service_role;

-- ---------- reference data --------------------------------------------
-- !! PLACEHOLDER PRICES (KRW) - roughly the old USD prices x 1,400, rounded.
-- !! Edit these (or UPDATE the rows later) before going live.
insert into public.plans (slug, name, price, extra_person_price, duration_minutes, description, sort_order) values
  ('quick',     'Tokyo Quick Shot',          99000, 69000, 30, '30-minute portrait session', 1),
  ('portrait',  'Full Portrait Session',    139000, 77000, 50, '50-minute portrait session', 2),
  ('fisheye',   'Fish Eye Session',         209000, 84000, 50, '50-minute fish-eye session', 3),
  ('signature', 'Signature Session',        265000, 91000, 50, '50-minute session, both lenses', 4),
  ('couple',    'Couple / Proposal Session',419000,     0, 50, '50-minute couples session, both lenses', 5)
on conflict (slug) do nothing;

-- Fixed UUIDs: lib/data.ts matches locations by these ids.
insert into public.locations (id, name, surcharge, sort_order) values
  ('11111111-1111-1111-1111-111111111111', 'Shibuya',  0, 1),
  ('22222222-2222-2222-2222-222222222222', 'Shinjuku', 0, 2)
on conflict (id) do nothing;

-- Placeholder opening hours: every day 10:00-19:00 (minutes since midnight).
insert into public.location_hours (location_id, weekday, open_minutes, close_minutes)
select l.id, d, 600, 1140
from public.locations l, generate_series(0, 6) d
on conflict do nothing;
