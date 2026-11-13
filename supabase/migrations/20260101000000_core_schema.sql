-- =====================================================================
-- Core schema: settings, catalogue, bookings, analytics.
-- All money is stored as integer KRW (원). There are no decimals / cents.
-- =====================================================================

-- ---------- helpers ---------------------------------------------------
create function public.set_updated_at()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  new.updated_at = now();
  return new;
end;
$$;

-- ---------- app_settings (single row) ---------------------------------
-- Every business rule that used to be hard-coded inside the old RPCs lives
-- here so it can be changed without a migration.
create table public.app_settings (
  id boolean primary key default true check (id),            -- forces a single row
  timezone text not null default 'Asia/Seoul',
  slot_step_minutes integer not null default 30 check (slot_step_minutes > 0),
  buffer_minutes integer not null default 30 check (buffer_minutes >= 0),
  max_concurrent_bookings integer not null default 1 check (max_concurrent_bookings > 0),
  min_notice_days integer not null default 2 check (min_notice_days >= 0),   -- "48 hours notice"
  hold_minutes integer not null default 30 check (hold_minutes > 0),         -- pending_payment slot hold
  extra_time_price_per_30min integer not null default 139000 check (extra_time_price_per_30min >= 0),
  -- cancellation / reschedule policy
  full_refund_hours integer not null default 48,       -- >= this many hours before: 100% refund / free reschedule
  partial_refund_hours integer not null default 24,    -- >= this many hours before: partial refund / paid reschedule
  partial_refund_percent integer not null default 50 check (partial_refund_percent between 0 and 100),
  reschedule_fee_percent integer not null default 50 check (reschedule_fee_percent between 0 and 100),
  updated_at timestamptz not null default now(),
  check (full_refund_hours > partial_refund_hours)
);
insert into public.app_settings (id) values (true);
create trigger app_settings_updated_at before update on public.app_settings
  for each row execute function public.set_updated_at();

-- ---------- members (studio staff) ------------------------------------
-- Staff who receive booking e-mails and can be assigned to a booking.
create table public.members (
  id uuid primary key default gen_random_uuid(),
  user_id uuid references auth.users(id) on delete set null,
  name text not null,
  email text not null unique,
  role text not null default 'photographer',
  status text not null default 'Active' check (status in ('Active', 'Inactive')),
  created_at timestamptz not null default now()
);

-- ---------- catalogue --------------------------------------------------
create table public.plans (
  id uuid primary key default gen_random_uuid(),
  slug text not null unique,
  name text not null,
  price integer not null check (price >= 0),
  extra_person_price integer not null default 0 check (extra_person_price >= 0),
  duration_minutes integer not null check (duration_minutes > 0),
  description text not null default '',
  sort_order integer not null default 0,
  is_active boolean not null default true,
  created_at timestamptz not null default now()
);

create table public.locations (
  id uuid primary key default gen_random_uuid(),
  name text not null,
  surcharge integer not null default 0 check (surcharge >= 0),
  sort_order integer not null default 0,
  is_active boolean not null default true,
  created_at timestamptz not null default now()
);

create table public.addons (
  id uuid primary key default gen_random_uuid(),
  slug text not null unique,
  name text not null,
  price integer not null check (price >= 0),
  sort_order integer not null default 0,
  is_active boolean not null default true,
  created_at timestamptz not null default now()
);

-- Opening hours per location and weekday (0 = Sunday ... 6 = Saturday).
-- A missing row means the location is closed that day.
create table public.location_hours (
  location_id uuid not null references public.locations(id) on delete cascade,
  weekday smallint not null check (weekday between 0 and 6),
  open_minutes integer not null check (open_minutes between 0 and 1439),
  close_minutes integer not null check (close_minutes between 1 and 1440),
  primary key (location_id, weekday),
  check (close_minutes > open_minutes)
);

-- Whole days that cannot be booked (holidays, vacations). NULL location = all.
create table public.blocked_dates (
  id uuid primary key default gen_random_uuid(),
  date date not null,
  location_id uuid references public.locations(id) on delete cascade,
  reason text,
  created_at timestamptz not null default now()
);
create index blocked_dates_date_idx on public.blocked_dates (date);

-- ---------- bookings ---------------------------------------------------
create table public.bookings (
  id uuid primary key default gen_random_uuid(),
  reference text not null unique,
  tourist_id uuid references auth.users(id) on delete set null,   -- owner (the customer)
  plan_id uuid not null references public.plans(id),
  location_id uuid not null references public.locations(id),
  assigned_member_id uuid references public.members(id) on delete set null,

  date date not null,
  start_minutes integer not null check (start_minutes between 0 and 1439),
  end_minutes integer not null,
  extra_duration_minutes integer not null default 0 check (extra_duration_minutes >= 0),
  group_size integer not null default 1 check (group_size between 1 and 10),

  -- customer snapshot (kept even if the auth user is deleted)
  client_name text not null,
  client_email text not null,
  client_phone text not null,
  client_country text not null default '',
  special_requests text not null default '',
  retouch_notes text not null default '',
  agreed_to_policy boolean not null default false,

  status text not null default 'pending_payment' check (status in (
    'pending_payment', 'pending_confirmation', 'confirmed',
    'pending_reschedule_confirmation', 'completed', 'cancelled'
  )),
  payment_status text not null default 'pending' check (payment_status in (
    'pending', 'paid', 'failed', 'partially_refunded', 'refunded', 'disputed'
  )),
  total_price integer not null check (total_price >= 0),          -- KRW
  refund_amount integer not null default 0 check (refund_amount >= 0),   -- KRW
  paid_at timestamptz,
  refunded_at timestamptz,

  hold_expires_at timestamptz,        -- only meaningful while pending_payment
  reschedule_count integer not null default 0,
  cancelled_at timestamptz,
  cancelled_reason text,

  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  check (end_minutes > start_minutes)
);
create index bookings_tourist_idx on public.bookings (tourist_id, date desc);
create index bookings_date_status_idx on public.bookings (date, status);
create index bookings_hold_idx on public.bookings (hold_expires_at) where status = 'pending_payment';
create trigger bookings_updated_at before update on public.bookings
  for each row execute function public.set_updated_at();

create table public.booking_addons (
  booking_id uuid not null references public.bookings(id) on delete cascade,
  addon_id uuid not null references public.addons(id),
  price_snapshot integer not null check (price_snapshot >= 0),    -- KRW at time of booking
  primary key (booking_id, addon_id)
);

-- ---------- analytics --------------------------------------------------
create table public.user_events (
  id bigint generated always as identity primary key,
  tourist_id uuid references auth.users(id) on delete set null,
  session_id text not null,
  event_type text not null,
  properties jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now()
);
create index user_events_tourist_idx on public.user_events (tourist_id, created_at desc);

-- ---------- internal helpers ------------------------------------------
-- Human-friendly unique booking reference, e.g. SO-7K3M9Q.
create function public._new_booking_reference()
returns text
language plpgsql
set search_path = ''
as $$
declare
  v_alphabet constant text := 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789';   -- no 0/O/1/I
  v_ref text;
  i int;
begin
  loop
    v_ref := 'SO-';
    for i in 1..6 loop
      v_ref := v_ref || substr(v_alphabet, 1 + floor(random() * length(v_alphabet))::int, 1);
    end loop;
    exit when not exists (select 1 from public.bookings where reference = v_ref);
  end loop;
  return v_ref;
end;
$$;

-- "Today" in the studio's timezone.
create function public._today()
returns date
language sql
stable
set search_path = ''
as $$
  select (now() at time zone (select timezone from public.app_settings))::date;
$$;

-- Absolute start instant of a booking.
create function public._booking_start(p_date date, p_start_minutes integer)
returns timestamptz
language sql
stable
set search_path = ''
as $$
  select (p_date::timestamp + make_interval(mins => p_start_minutes))
         at time zone (select timezone from public.app_settings);
$$;
