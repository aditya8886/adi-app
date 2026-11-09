// Adi on Supabase: gives the app the same window.claude.use() it had on claude.ai,
// backed by Supabase sign-in, tables, storage and live updates.
(function(){
  const CFG = window.ADI_CONFIG || {};
  const ready = CFG.url && CFG.anonKey && !/YOUR_/.test(CFG.url + CFG.anonKey);
  const sb = ready ? window.supabase.createClient(CFG.url, CFG.anonKey, {auth:{persistSession:true, autoRefreshToken:true}}) : null;
  window.ADI_SB = sb;
  const MEDIA = ready ? CFG.url.replace(/\/$/, "") + "/storage/v1/object/public/media/" : "";
  const DEMO = window.ADI_DEMO_MEDIA || {};
  window.ADI_BLOB = id => DEMO[id] ? "demo-media/" + DEMO[id] : MEDIA + String(id).split("/").map(encodeURIComponent).join("/");

  const err = (e, code) => { const x = new Error((e && e.message) || code || "error"); x.code = code || (e && e.code) || "unknown"; return x; };

  // ---------- path → table ----------
  function where(path){
    const p = String(path).split("/");
    if (p[0] === "data" && p[1] === "users" && p[3] === "prefs") return {table:"prefs", id:p[2]};
    return {table:p[0], id:p[1]};
  }
  const doc = (id, data) => ({id, exists:true, data:() => data});
  const snapOf = rows => ({docs: rows.map(r => doc(r.id, r.data)), metadata:{fromCache:false, hasPendingWrites:false}});
  const OWNER = {threads:1, messages:1};
  const rowData = (table, r) => OWNER[table] ? {...r.data, _owner:r.owner} : r.data;

  // one live cache per table, shared by all listeners
  const caches = {};
  function cache(table){
    if (caches[table]) return caches[table];
    const c = caches[table] = {rows:new Map(), subs:new Set(), loaded:false};
    const emit = () => { const rows = [...c.rows.entries()].map(([id, data]) => ({id, data})); c.subs.forEach(s => s(rows)); };
    c.emit = emit;
    c.load = async () => {
      let q = sb.from(table).select(OWNER[table] ? "id,data,owner" : "id,data");
      if (table === "messages") q = q.order("created_at", {ascending:false}).limit(3000);
      const {data, error} = await q;
      if (error) { c.subs.forEach(s => s(null, err(error))); return; }
      c.rows = new Map(data.map(r => [String(r.id), rowData(table, r)])); c.loaded = true; emit();
    };
    c.ch = sb.channel("t-" + table).on("postgres_changes", {event:"*", schema:"public", table}, pl => {
      if (pl.eventType === "DELETE") { if (pl.old && pl.old.id != null) c.rows.delete(String(pl.old.id)); }
      else if (pl.new && pl.new.id != null) c.rows.set(String(pl.new.id), rowData(table, pl.new));
      emit();
    }).subscribe(st => { if (st === "SUBSCRIBED" && c.loaded) c.load(); });
    c.load();
    return c;
  }
  // after our own write, update the cache at once (live updates can lag a second)
  const local = (table, id, data) => { const c = caches[table]; if (!c) return; if (data === undefined) c.rows.delete(String(id)); else c.rows.set(String(id), data); c.emit(); };

  let me = null;
  const db = {
    collection(name){
      return {
        onSnapshot(cb, onErr){
          const c = cache(name);
          const s = (rows, e) => { if (e) { onErr && onErr(e); return; } cb(snapOf(rows)); };
          c.subs.add(s); if (c.loaded) s([...c.rows.entries()].map(([id, data]) => ({id, data})));
          return () => c.subs.delete(s);
        },
        async add(data){
          const row = {data}; if (name === "messages") row.tid = data.tid;
          const {data:out, error} = await sb.from(name).insert(row).select(OWNER[name] ? "id,data,owner" : "id,data").single();
          if (error) throw err(error, error.code === "42501" ? "permission_denied" : "unknown");
          local(name, out.id, rowData(name, out)); return doc(out.id, data);
        },
        doc(id){ return db.doc(name + "/" + id); }
      };
    },
    doc(path){
      const {table, id} = where(path);
      return {
        id,
        async set(data){
          const {error} = await sb.from(table).upsert({id, data});
          if (error) throw err(error, error.code === "42501" ? "invalid_argument" : (/too large|payload/i.test(error.message) ? "quota_exceeded" : "unknown"));
          local(table, id, OWNER[table] ? {...data, _owner:me} : data);
        },
        async delete(){ const {error} = await sb.from(table).delete().eq("id", id); if (error) throw err(error); local(table, id); },
        async get(){ const {data, error} = await sb.from(table).select("id,data").eq("id", id).maybeSingle(); if (error) throw err(error); return data ? doc(id, data.data) : {id, exists:false, data:() => undefined}; },
        onSnapshot(cb, onErr){
          const c = cache(table);
          const s = (rows, e) => {
            if (e) { onErr && onErr(e); return; }
            const r = rows.find(x => String(x.id) === String(id));
            cb(r ? {...doc(id, r.data), metadata:{hasPendingWrites:false, fromCache:false}} : {id, exists:false, data:() => undefined, metadata:{hasPendingWrites:false, fromCache:false}});
          };
          c.subs.add(s); if (c.loaded) s([...c.rows.entries()].map(([i, data]) => ({id:i, data})));
          return () => c.subs.delete(s);
        }
      };
    }
  };

  let session = null, isAdmin = false;
  const user = {
    id: async () => me,
    can: async () => true,
    canEdit: async () => isAdmin,
    profiles: async ids => { const n = session && session.user.user_metadata && session.user.user_metadata.name; return n && ids.includes(me) ? {[me]:{name:n}} : {}; },
    email: () => session && session.user.email,
    signOut: async () => { await sb.auth.signOut(); localStorage.removeItem("adi-pending-name"); location.reload(); }
  };

  const TYPES = {"image/jpeg":"jpg", "image/png":"png", "image/webp":"webp", "video/mp4":"mp4", "video/webm":"webm"};
  const assets = {
    async upload(file, opts){
      const type = (opts && opts.type) || file.type || "application/octet-stream";
      if (!TYPES[type]) throw err(null, "unsupported_type");
      if (file.size > 20 * 1024 * 1024) throw err(null, "too_large");
      const id = me + "/" + Date.now().toString(36) + Math.random().toString(36).slice(2, 8) + "." + TYPES[type];
      const {error} = await sb.storage.from("media").upload(id, file, {contentType:type, cacheControl:"31536000", upsert:false});
      if (error) throw err(error, /exceed|size/i.test(error.message) ? "too_large" : /mime|type/i.test(error.message) ? "unsupported_type" : /rate/i.test(error.message) ? "rate_limited" : "quota_or_state");
      return {id};
    },
    async delete(id){ if (DEMO[id] || !String(id).startsWith(me + "/")) return; await sb.storage.from("media").remove([id]); }
  };

  // ---------- sign-in screen ----------
  function authScreen(){
    return new Promise(resolve => {
      const el = document.createElement("div"); el.id = "auth";
      el.innerHTML = `<div class="au-card">
        <div class="au-logo">Adi</div>
        <p class="au-sub">Share photos, clips and moments with your people.</p>
        <div class="au-tabs" role="tablist"><button type="button" data-m="up" aria-selected="true">Create account</button><button type="button" data-m="in" aria-selected="false">Log in</button></div>
        <form id="au-f" novalidate>
          <label class="au-f" id="au-nl">Your name<input id="au-n" autocomplete="name" maxlength="40" placeholder="e.g. Riya Sharma"></label>
          <label class="au-f">Email<input id="au-e" type="email" autocomplete="email" inputmode="email" placeholder="you@example.com"></label>
          <label class="au-f">Password<input id="au-p" type="password" autocomplete="new-password" minlength="6" placeholder="At least 6 characters"></label>
          <div class="au-msg" id="au-msg" role="status"></div>
          <button class="au-btn" id="au-go">Create account</button>
          <button type="button" class="au-link" id="au-forgot" hidden>Forgot password?</button>
        </form>
        <p class="au-fine">Adi is a test version. Money shown in the app is a preview and no real payments happen.</p></div>`;
      document.body.appendChild(el);
      const sp = document.getElementById("splash"); if (sp) sp.remove();
      let mode = "up";
      const $ = s => el.querySelector(s), msg = (t, ok) => { $("#au-msg").textContent = t; $("#au-msg").className = "au-msg" + (ok ? " ok" : ""); };
      const setMode = m => { mode = m; el.querySelectorAll("[data-m]").forEach(b => b.setAttribute("aria-selected", b.dataset.m === m)); $("#au-nl").hidden = m !== "up"; $("#au-go").textContent = m === "up" ? "Create account" : "Log in"; $("#au-p").autocomplete = m === "up" ? "new-password" : "current-password"; $("#au-forgot").hidden = m !== "in"; msg(""); };
      el.querySelectorAll("[data-m]").forEach(b => b.onclick = () => setMode(b.dataset.m));
      $("#au-forgot").onclick = async () => {
        const e = $("#au-e").value.trim(); if (!/^\S+@\S+\.\S+$/.test(e)) return msg("Type your email first, then tap Forgot password.");
        const {error} = await sb.auth.resetPasswordForEmail(e, {redirectTo:location.origin + location.pathname});
        msg(error ? "Couldn't send the email. Try again in a few minutes." : "Check your email for a link to set a new password.", !error);
      };
      $("#au-f").onsubmit = async ev => {
        ev.preventDefault();
        const n = $("#au-n").value.trim(), e = $("#au-e").value.trim(), p = $("#au-p").value;
        if (mode === "up" && n.length < 2) return msg("Tell us your name.");
        if (!/^\S+@\S+\.\S+$/.test(e)) return msg("That email doesn't look right.");
        if (p.length < 6) return msg("Use a password with at least 6 characters.");
        $("#au-go").disabled = true; msg(mode === "up" ? "Creating your account…" : "Logging in…", true);
        const r = mode === "up" ? await sb.auth.signUp({email:e, password:p, options:{data:{name:n}}}) : await sb.auth.signInWithPassword({email:e, password:p});
        $("#au-go").disabled = false;
        if (r.error) {
          const m = r.error.message || "";
          return msg(/already registered|already exists/i.test(m) ? "There's already an account with this email. Tap Log in." : /invalid login/i.test(m) ? "Wrong email or password." : /not confirmed/i.test(m) ? "Confirm your email first. Check your inbox." : /rate|too many/i.test(m) ? "Too many tries. Wait a minute and try again." : "Couldn't do that: " + m);
        }
        if (!r.data.session) return msg("Almost done! We sent you an email. Tap the link in it, then come back and log in.", true);
        el.remove(); resolve(r.data.session);
      };
    });
  }

  window.ADI_RESET_PW = async () => {
    const p = prompt("Type a new password for Adi (at least 6 characters):"); if (!p) return;
    if (p.length < 6) return alert("That password is too short. Use the email link again to try once more.");
    const {error} = await sb.auth.updateUser({password:p});
    alert(error ? "Couldn't change your password. Use the email link again." : "Password changed. You're logged in.");
  };

  let started = null;
  function start(){
    if (started) return started;
    started = (async () => {
      if (!sb) return null;
      let {data:{session:s}} = await sb.auth.getSession();
      if (!s) s = await authScreen();
      session = s; me = s.user.id;
      sb.auth.onAuthStateChange((ev, ns) => { if (ev === "SIGNED_OUT") location.reload(); if (ns) session = ns; if (ev === "PASSWORD_RECOVERY") setTimeout(() => window.ADI_RESET_PW && window.ADI_RESET_PW(), 300); });
      try { const {data} = await sb.rpc("claim_admin"); isAdmin = !!data; } catch (e) {}
      return true;
    })();
    return started;
  }

  window.claude = {
    async use(name){
      const ok = await start(); if (!ok) return null;
      if (name === "db") return db;
      if (name === "user") return user;
      if (name === "assets") return assets;
      return null; // "sample" (Claude AI features) is only on claude.ai
    }
  };
  if (!ready) window.ADI_NOT_CONFIGURED = true;
})();
