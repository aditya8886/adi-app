-- Adi database setup. Run this once in Supabase: SQL Editor > New query > paste > Run.
-- Safe to run again: it drops and recreates the policies, and keeps your data.

-- ---------- tables (each row holds one JSON document, like the prototype) ----------
create table if not exists public.users    (id text primary key, data jsonb not null default '{}', updated_at timestamptz not null default now());
create table if not exists public.prefs    (id text primary key, data jsonb not null default '{}');
create table if not exists public.questions(id uuid primary key default gen_random_uuid(), data jsonb not null default '{}', created_at timestamptz not null default now());
create table if not exists public.board    (id text primary key, data jsonb not null default '{}');
create table if not exists public.feedback (id text primary key, data jsonb not null default '{}');
create table if not exists public.threads  (id text primary key, data jsonb not null default '{}', owner text not null default (auth.uid())::text);
create table if not exists public.messages (id uuid primary key default gen_random_uuid(), tid text not null, data jsonb not null default '{}', owner text not null default (auth.uid())::text, created_at timestamptz not null default now());
create index if not exists messages_tid on public.messages(tid);
create table if not exists public.admins   (uid text primary key);

-- ---------- helpers ----------
create or replace function public.is_admin() returns boolean language sql stable security definer set search_path = public as
$$ select exists(select 1 from public.admins where uid = (auth.uid())::text) $$;

-- The first person who signs in becomes the admin (that should be you). Later sign-ins are normal users.
create or replace function public.claim_admin() returns boolean language plpgsql security definer set search_path = public as
$$ begin
  if auth.uid() is null then return false; end if;
  if not exists(select 1 from public.admins) then insert into public.admins(uid) values ((auth.uid())::text); end if;
  return public.is_admin();
end $$;
grant execute on function public.claim_admin() to authenticated;
grant execute on function public.is_admin() to authenticated;

create or replace function public.in_thread(t text) returns boolean language sql stable security definer set search_path = public as
$$ select exists(select 1 from public.threads th where th.id = t and (th.data->'members' ? (auth.uid())::text or th.data->'members' ? '*')) $$;
grant execute on function public.in_thread(text) to authenticated;

-- ---------- row level security ----------
alter table public.users     enable row level security;
alter table public.prefs     enable row level security;
alter table public.questions enable row level security;
alter table public.board     enable row level security;
alter table public.feedback  enable row level security;
alter table public.threads   enable row level security;
alter table public.messages  enable row level security;
alter table public.admins    enable row level security;

do $$ declare r record; begin
  for r in select policyname, tablename from pg_policies where schemaname='public' and tablename in ('users','prefs','questions','board','feedback','threads','messages','admins') loop
    execute format('drop policy %I on public.%I', r.policyname, r.tablename);
  end loop;
end $$;

-- profiles and posts: every signed-in person can read; you can only change your own
create policy users_read   on public.users for select to authenticated using (true);
create policy users_insert on public.users for insert to authenticated with check (id = (auth.uid())::text or public.is_admin());
create policy users_update on public.users for update to authenticated using (id = (auth.uid())::text or public.is_admin()) with check (id = (auth.uid())::text or public.is_admin());
create policy users_delete on public.users for delete to authenticated using (id = (auth.uid())::text or public.is_admin());

-- private settings (kept posts, blocked people, muted words): only you
create policy prefs_all on public.prefs for all to authenticated using (id = (auth.uid())::text) with check (id = (auth.uid())::text);

-- anonymous questions: anyone can ask; only the person asked can read or delete them
create policy q_insert on public.questions for insert to authenticated with check (true);
create policy q_read   on public.questions for select to authenticated using (data->>'to' = (auth.uid())::text or public.is_admin());
create policy q_delete on public.questions for delete to authenticated using (data->>'to' = (auth.uid())::text or public.is_admin());

-- brand gigs board: everyone reads, only the admin posts
create policy board_read  on public.board for select to authenticated using (true);
create policy board_write on public.board for all to authenticated using (public.is_admin()) with check (public.is_admin());

-- feedback and reports: you write your own; only the admin reads everyone's
create policy fb_read  on public.feedback for select to authenticated using (id = (auth.uid())::text or public.is_admin());
create policy fb_write on public.feedback for insert to authenticated with check (id = (auth.uid())::text);
create policy fb_upd   on public.feedback for update to authenticated using (id = (auth.uid())::text) with check (id = (auth.uid())::text);

-- private chats: only the people in a chat can see it or its messages
create policy th_read   on public.threads for select to authenticated using (data->'members' ? (auth.uid())::text or data->'members' ? '*');
create policy th_insert on public.threads for insert to authenticated with check (owner = (auth.uid())::text and data->'members' ? (auth.uid())::text and not data->'members' ? '*');
create policy th_update on public.threads for update to authenticated using (owner = (auth.uid())::text) with check (owner = (auth.uid())::text and not data->'members' ? '*');
create policy th_delete on public.threads for delete to authenticated using (owner = (auth.uid())::text or public.is_admin());
create policy msg_read   on public.messages for select to authenticated using (public.in_thread(tid));
create policy msg_insert on public.messages for insert to authenticated with check (owner = (auth.uid())::text and public.in_thread(tid));
create policy msg_delete on public.messages for delete to authenticated using (owner = (auth.uid())::text or public.is_admin());

create policy admins_read on public.admins for select to authenticated using (uid = (auth.uid())::text);

-- ---------- live updates ----------
do $$ declare t text; begin
  foreach t in array array['users','questions','board','threads','messages','feedback'] loop
    begin execute format('alter publication supabase_realtime add table public.%I', t); exception when duplicate_object then null; end;
  end loop;
end $$;

-- ---------- photo and video storage ----------
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('media', 'media', true, 20971520, array['image/jpeg','image/png','image/webp','video/mp4','video/webm'])
on conflict (id) do update set public = true, file_size_limit = excluded.file_size_limit, allowed_mime_types = excluded.allowed_mime_types;

drop policy if exists media_read on storage.objects;
drop policy if exists media_insert on storage.objects;
drop policy if exists media_delete on storage.objects;
create policy media_read   on storage.objects for select using (bucket_id = 'media');
create policy media_insert on storage.objects for insert to authenticated with check (bucket_id = 'media' and owner = auth.uid());
create policy media_delete on storage.objects for delete to authenticated using (bucket_id = 'media' and (owner = auth.uid() or public.is_admin()));

insert into public.threads (id, data, owner) values ('t-community', '{"id":"t-community","members":["*"],"name":"Adi Community"}'::jsonb, 'demo_priya') on conflict (id) do nothing;
