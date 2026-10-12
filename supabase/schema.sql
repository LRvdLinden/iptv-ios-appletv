-- Bingr-accounts: tabel voor tv-koppelcodes (QR-login op Apple TV, Android TV en Fire TV).
-- Alleen de Edge Function (service role) leest en schrijft hierin; RLS zonder policies houdt alle anderen buiten.
create table if not exists public.device_codes (
  code        text primary key,
  poll_secret text not null,
  device      text,
  user_id     uuid references auth.users(id) on delete cascade,
  created_at  timestamptz not null default now(),
  expires_at  timestamptz not null
);
alter table public.device_codes enable row level security;
revoke all on public.device_codes from anon, authenticated;
create index if not exists device_codes_expires_idx on public.device_codes (expires_at);
