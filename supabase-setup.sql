-- Bea's Play — Supabase setup. Paste this whole file into the Supabase
-- SQL Editor and press Run. ONE THING TO EDIT FIRST: replace CHANGE-ME-PIN
-- below with the grown-up PIN you want (keep the quotes).

create extension if not exists pgcrypto;

-- the app data: one row holding everything (videos, questions, words, ...)
create table if not exists public.bea_data (
  id int primary key,
  data jsonb not null,
  updated_at timestamptz default now()
);

-- the grown-up PIN, stored hashed (never in plaintext)
create table if not exists public.bea_secret (
  id int primary key,
  pin_hash text not null
);

insert into public.bea_secret (id, pin_hash)
values (1, crypt('CHANGE-ME-PIN', gen_salt('bf')))
on conflict (id) do update set pin_hash = excluded.pin_hash;

alter table public.bea_data enable row level security;
alter table public.bea_secret enable row level security;

-- anyone may READ the app data (the app itself is public);
-- nobody may write directly — writes only pass through the PIN-checked
-- function below. bea_secret has no policies at all: fully locked.
drop policy if exists "public read" on public.bea_data;
create policy "public read" on public.bea_data for select using (true);

create or replace function public.save_bea_data(pin text, payload jsonb)
returns boolean
language plpgsql
security definer
set search_path = public
as $$
begin
  if not exists (
    select 1 from bea_secret s
    where s.id = 1 and s.pin_hash = crypt(pin, s.pin_hash)
  ) then
    return false;
  end if;
  insert into bea_data (id, data, updated_at)
  values (1, payload, now())
  on conflict (id) do update set data = excluded.data, updated_at = now();
  return true;
end;
$$;
