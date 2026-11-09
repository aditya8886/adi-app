-- Adi demo week: the 6 demo accounts post twice a day (12 pm and 7 pm India time) for 7 days.
-- First add the demo accounts from the app (Settings > Add demo accounts), then run this once.
create extension if not exists pg_cron with schema pg_catalog;
create table if not exists public.demo_queue (n serial primary key, uid text not null, post jsonb not null, done boolean not null default false);
alter table public.demo_queue enable row level security;
truncate public.demo_queue restart identity;
insert into public.demo_queue (uid, post) values
  ('demo_priya', '{"media": [{"id": "7551c6b335df49db5507a959976bc79e", "type": "image", "filter": "warm"}], "caption": "Sunday special: kanda poha with extra sev 😋 Who''s coming over? #punefood #nashta", "location": "Pune"}'::jsonb),
  ('demo_arjun', '{"media": [{"id": "2bc709d3c1c44d2723adc702e60139a2", "type": "image", "filter": "normal"}], "caption": "Chai break at 4,000m. Haath kaanp rahe hain but view dekho ⛰️ #ladakh #roadtrip", "location": "Ladakh"}'::jsonb),
  ('demo_memes', '{"media": [{"id": "fe3af0002515455f72b55fc172ca084d", "type": "image", "filter": "normal"}], "caption": "Me: sirf 5 minute phone dekhunga\nAlso me at 2 AM: 😵 #relatable #desimemes"}'::jsonb),
  ('demo_kabir', '{"media": [{"id": "dc8135d11a622dc44d0dde6d1f801473", "type": "image", "filter": "cool"}], "caption": "Day 12 of #pushup30. 40 pushups, no breaks. Kal 45! Kaun saath hai? 💪 #fitness", "location": "Delhi"}'::jsonb),
  ('demo_neha', '{"media": [{"id": "95c4f25cfb881b878ef9da0d89235ac6", "type": "image", "filter": "normal"}], "caption": "Built a tiny expense tracker in one evening. Code is simple, idea is powerful 👩‍💻 #coding #buildinpublic", "location": "Bengaluru"}'::jsonb),
  ('demo_meera', '{"media": [{"id": "04def75889801464a1b29cac805abed2", "type": "image", "filter": "warm"}], "caption": "Chelsea ne aaj phir mera chappal chura liya 🐶😂 #doglife", "location": "Jaipur"}'::jsonb),
  ('demo_priya', '{"media": [{"id": "a74baf876b6248fbdd15b89fe20a3131", "type": "image", "filter": "vivid"}], "caption": "Trying a new chutney recipe. Imli + gud + thoda sa jeera. Rate it 1 to 10? 🍯 #recipe", "location": "Pune"}'::jsonb),
  ('demo_arjun', '{"media": [{"id": "9f0555a9b0bc01d30cdf1850de3fa458", "type": "image", "filter": "cool"}], "caption": "Spiti mein network nahi, sirf sukoon 🏔️ #spiti #travelindia", "location": "Spiti"}'::jsonb),
  ('demo_memes', '{"media": [{"id": "0c28df17b73121be7997c7d14eda757e", "type": "image", "filter": "normal"}], "caption": "When mom says ''ghar pe khana hai'' but you already ordered Swiggy 🙃 #desimemes"}'::jsonb),
  ('demo_kabir', '{"media": [{"id": "d5dfa03757dd76e72c052355bf37e106", "type": "image", "filter": "normal"}], "caption": "Rest day = stretching day. Your back will thank you 🧘 #fitnesstips", "location": "Delhi"}'::jsonb),
  ('demo_neha', '{"media": [{"id": "c0db438c1355cef1837d96aadf1f9cc3", "type": "image", "filter": "normal"}], "caption": "3 free resources that taught me more than college 📚 1) docs 2) side projects 3) asking questions. #techtips", "location": "Bengaluru"}'::jsonb),
  ('demo_meera', '{"media": [{"id": "3954f622727f59129670ad10270e7f37", "type": "image", "filter": "warm"}], "caption": "Golden hour, golden boy ✨ #petsofadi", "location": "Jaipur"}'::jsonb),
  ('demo_priya', '{"media": [{"id": "7551c6b335df49db5507a959976bc79e", "type": "image", "filter": "warm"}], "caption": "Shabashi goal update: 70% there for the new oven! Thank you all 🙏❤️ #grateful", "location": "Pune"}'::jsonb),
  ('demo_arjun', '{"media": [{"id": "ff5226c29cd3f0d8dc8e2bfdea5a3a85", "type": "image", "filter": "vivid"}], "caption": "Last day of the trip. Next destination kahan? Comment karo 👇 #wanderlust", "location": "Manali"}'::jsonb);

create or replace function public.adi_demo_tick() returns void language plpgsql security definer set search_path = public as $$
declare q record; ms bigint := (extract(epoch from now()) * 1000)::bigint; pid text; c text[] := array['Wah! 😍', 'Ye toh kamaal hai 🔥', 'Mujhe bhi chahiye!', 'Next time saath chalenge', '😂😂 so true', 'Saved this, thanks!', 'Bahut badhiya 👏', 'Recipe please!!'];
begin
  select * into q from demo_queue where not done order by n limit 1;
  if q is null then perform cron.unschedule('adi-demo-posts'); return; end if;
  pid := 'dq-' || q.n || '-' || ms;
  update users set data = jsonb_set(data, '{posts}', coalesce(data->'posts', '[]'::jsonb) || jsonb_build_array(q.post || jsonb_build_object('id', pid, 'at', ms))), updated_at = now() where id = q.uid;
  update users set data = jsonb_set(data, '{likes}', coalesce(data->'likes', '{}'::jsonb) || jsonb_build_object(pid, ms + (random() * 600000)::bigint))
    where id in (select id from users where id like 'demo\_%' and id <> q.uid order by random() limit 3);
  update users set data = jsonb_set(data, '{comments}', coalesce(data->'comments', '[]'::jsonb) || jsonb_build_array(jsonb_build_object('id', 'dc' || ms, 'pid', pid, 'text', c[1 + floor(random() * array_length(c, 1))::int], 'at', ms + 120000)))
    where id = (select id from users where id like 'demo\_%' and id <> q.uid order by random() limit 1);
  update demo_queue set done = true where n = q.n;
end $$;

select cron.unschedule(jobid) from cron.job where jobname = 'adi-demo-posts';
select cron.schedule('adi-demo-posts', '30 6,13 * * *', 'select public.adi_demo_tick()');
select public.adi_demo_tick();
