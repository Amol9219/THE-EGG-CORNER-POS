import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { createClient } from "npm:@supabase/supabase-js@2.57.0";

const cors = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, apikey, content-type, x-client-info",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
  "Content-Type": "application/json",
};

Deno.serve(async (req: Request) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors });
  if (req.method !== "POST") return new Response(JSON.stringify({ error: "Method not allowed" }), { status: 405, headers: cors });
  try {
    const url = Deno.env.get("SUPABASE_URL");
    const serviceKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
    const anonKey = Deno.env.get("SUPABASE_ANON_KEY");
    if (!url || !serviceKey || !anonKey) throw new Error("Server auth configuration is missing.");
    const authHeader = req.headers.get("Authorization");
    if (!authHeader?.startsWith("Bearer ")) return new Response(JSON.stringify({ error: "Login required." }), { status: 401, headers: cors });
    const token = authHeader.slice(7);
    const caller = createClient(url, anonKey, { auth: { persistSession: false, autoRefreshToken: false }, global: { headers: { Authorization: authHeader } } });
    const { data: authData, error: authError } = await caller.auth.getUser(token);
    if (authError || !authData.user) return new Response(JSON.stringify({ error: "Session invalid. Please log in again." }), { status: 401, headers: cors });
    const admin = createClient(url, serviceKey, { auth: { persistSession: false, autoRefreshToken: false } });
    const { data: owner, error: ownerError } = await admin.from("profiles").select("id,role,is_active,outlet_id").eq("id", authData.user.id).maybeSingle();
    if (ownerError || !owner || owner.is_active !== true) return new Response(JSON.stringify({ error: "Active account required." }), { status: 403, headers: cors });
    const body = await req.json();
    const action = String(body.action || "invite");
    const redirectTo = "https://tec-masala-business.vercel.app/?auth_action=password";
    const { data: activePartners } = owner.role === "co_owner"
      ? await admin.from("profiles").select("id").eq("role", "co_owner").eq("is_active", true)
      : { data: [] as { id: string }[] };
    const partnerIds = new Set((activePartners || []).map((p: { id: string }) => p.id));
    if (owner.role === "co_owner") partnerIds.add(owner.id);
    const canManageTarget = (target: { id?: string; role?: string; staff_role?: string | null; outlet_id?: string | null; created_by?: string | null }) => {
      if (target.id === owner.id) return false;
      if (owner.role === "owner") return target.created_by === owner.id;
      if (owner.role === "co_owner") return target.role === "outlet" && !target.staff_role && !!target.created_by && partnerIds.has(target.created_by);
      if (owner.role === "outlet") return target.role === "outlet" && ["waiter", "kitchen", "counter"].includes(String(target.staff_role || "")) && !!owner.outlet_id && target.outlet_id === owner.outlet_id && target.created_by === owner.id;
      return false;
    };
    if (["get_login_email", "reset_password", "set_password", "update_login_email", "delete_inactive_user"].includes(action)) {
      const userId = String(body.user_id || "").trim();
      if (!userId) throw new Error("User ID आवश्यक आहे.");
      const { data: target, error: targetError } = await admin.from("profiles").select("id,role,staff_role,outlet_id,is_active,deleted_at,created_by").eq("id", userId).maybeSingle();
      if (targetError || !target) throw new Error("User profile सापडला नाही.");
      const canReadPartnerLogin = action === "get_login_email" && owner.role === "co_owner" && target.role === "co_owner";
      if (!canManageTarget(target) && !canReadPartnerLogin) return new Response(JSON.stringify({ error: "या User चे Login व्यवस्थापन करण्याची परवानगी नाही." }), { status: 403, headers: cors });
      if (target.deleted_at && !["get_login_email", "delete_inactive_user"].includes(action)) throw new Error("Archived User चे Login बदलता येणार नाही. History सुरक्षित ठेवली आहे.");
      if (action === "get_login_email") {
        const { data: authTarget, error: authTargetError } = await admin.auth.admin.getUserById(userId);
        if (authTargetError || !authTarget?.user?.email) throw new Error("Login Email मिळाला नाही.");
        return new Response(JSON.stringify({ ok: true, email: authTarget.user.email }), { status: 200, headers: cors });
      }
      if (action === "delete_inactive_user") {
        if (userId === authData.user.id) throw new Error("स्वतःचा login delete करता येणार नाही.");
        if (target.is_active === true) throw new Error("फक्त Inactive User delete करता येतो.");
        if (target.deleted_at) throw new Error("हा User आधीच delete केलेला आहे.");
        const { error: markError } = await admin.from("profiles").update({ deleted_at: new Date().toISOString() }).eq("id", userId).eq("is_active", false);
        if (markError) throw new Error("User archive करता आला नाही: " + markError.message);
        return new Response(JSON.stringify({ ok: true, message: "Inactive login archive केला; bills आणि history सुरक्षित ठेवली." }), { status: 200, headers: cors });
      }
    }
    if (action === "create_restaurant_staff") {
      if (owner.role !== "outlet" || !owner.outlet_id) return new Response(JSON.stringify({ error: "Only an active Outlet account can create its own staff logins." }), { status: 403, headers: cors });
      const email = String(body.email || "").trim().toLowerCase();
      const full_name = String(body.full_name || "").trim();
      const mobile = String(body.mobile || "").trim() || null;
      const staff_role = String(body.staff_role || "");
      const password = String(body.password || "");
      const waiter_code = String(body.waiter_code || "").trim() || null;
      if (!/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(email) || email.length > 254) throw new Error("Valid email address required.");
      if (!full_name || full_name.length > 120 || (mobile && mobile.length > 30)) throw new Error("Valid staff name and mobile are required.");
      if (!["waiter", "kitchen", "counter"].includes(staff_role)) throw new Error("Choose Waiter, Kitchen, or Counter role.");
      if (password.length < 8 || password.length > 128) throw new Error("Password must be 8 to 128 characters.");
      const { data: outlet, error: outletError } = await admin.from("outlets").select("id,is_active").eq("id", owner.outlet_id).maybeSingle();
      if (outletError || !outlet || outlet.is_active !== true) throw new Error("This outlet is inactive or unavailable.");
      const { data: created, error: createError } = await admin.auth.admin.createUser({ email, password, email_confirm: true, user_metadata: { full_name } });
      if (createError || !created.user) throw new Error(createError?.message || "Could not create staff login.");
      const userId = created.user.id;
      const { error: profileError } = await admin.from("profiles").insert({ id: userId, full_name, mobile, role: "outlet", staff_role, outlet_id: owner.outlet_id, is_active: true, created_by: authData.user.id });
      if (profileError) {
        await admin.auth.admin.deleteUser(userId);
        throw new Error("Staff profile creation failed: " + profileError.message);
      }
      if (staff_role === "waiter") {
        const { error: waiterError } = await admin.from("restaurant_waiters").insert({ outlet_id: owner.outlet_id, waiter_name: full_name, waiter_code, created_by: authData.user.id, user_id: userId });
        if (waiterError) {
          await admin.from("profiles").delete().eq("id", userId);
          await admin.auth.admin.deleteUser(userId);
          throw new Error("Waiter setup failed: " + waiterError.message);
        }
      }
      return new Response(JSON.stringify({ ok: true, email, staff_role }), { status: 200, headers: cors });
    }
    if (action === "create_outlet_user" && !["owner", "co_owner"].includes(owner.role)) return new Response(JSON.stringify({ error: "Only Owner or Partnership can create outlet logins." }), { status: 403, headers: cors });
    if (action === "invite" && !["owner", "co_owner"].includes(owner.role)) return new Response(JSON.stringify({ error: "Only Owner or Partnership can invite users." }), { status: 403, headers: cors });
    if (action === "set_password") {
      const userId = String(body.user_id || "").trim();
      const password = String(body.password || "");
      if (!userId || password.length < 8 || password.length > 128) throw new Error("User ID आणि 8 ते 128 अक्षरांचा password आवश्यक आहे.");
      const { error: setError } = await admin.auth.admin.updateUserById(userId, { password });
      if (setError) throw new Error(setError.message);
      return new Response(JSON.stringify({ ok: true, message: "Password बदलला." }), { status: 200, headers: cors });
    }
    if (action === "reset_password") {
      const userId = String(body.user_id || "").trim();
      if (!userId) throw new Error("User ID required.");
      const { data: profileTarget, error: targetError } = await admin.from("profiles").select("id,is_active").eq("id", userId).maybeSingle();
      if (targetError || !profileTarget) throw new Error("User profile not found.");
      if (!profileTarget.is_active) throw new Error("पहिले User profile Active करा, मग password reset link तयार करा.");
      const { data: targetAuth, error: targetAuthError } = await admin.auth.admin.getUserById(userId);
      const targetEmail = targetAuth?.user?.email;
      if (targetAuthError || !targetEmail) throw new Error("या User चा login email मिळाला नाही.");
      const { data: reset, error: resetError } = await admin.auth.admin.generateLink({ type: "recovery", email: targetEmail, options: { redirectTo } });
      if (resetError || !reset?.properties?.action_link) throw new Error(resetError?.message || "Password reset link तयार करता आली नाही.");
      return new Response(JSON.stringify({ ok: true, email: targetEmail, invite_url: reset.properties.action_link, message: "Password reset link तयार आहे; User ला सुरक्षितपणे पाठवा." }), { status: 200, headers: cors });
    }
    if (action === "update_login_email") {
      const userId = String(body.user_id || "").trim();
      const nextEmail = String(body.email || "").trim().toLowerCase();
      if (!userId || !/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(nextEmail) || nextEmail.length > 254) throw new Error("User ID आणि योग्य नवीन email आवश्यक आहे.");
      const { data: profileTarget, error: targetError } = await admin.from("profiles").select("id").eq("id", userId).maybeSingle();
      if (targetError || !profileTarget) throw new Error("User profile not found.");
      const { error: updateAuthError } = await admin.auth.admin.updateUserById(userId, { email: nextEmail, email_confirm: false });
      if (updateAuthError) throw new Error(updateAuthError.message);
      return new Response(JSON.stringify({ ok: true, email: nextEmail, message: "Login email change request स्वीकारली. Auth settings नुसार नवीन email confirm करावा लागू शकतो." }), { status: 200, headers: cors });
    }
    if (!["invite", "create_outlet_user"].includes(action)) throw new Error("Unsupported action.");
    const email = String(body.email || "").trim().toLowerCase();
    const full_name = String(body.full_name || "").trim();
    const mobile = String(body.mobile || "").trim() || null;
    const role = String(body.role || "");
    const outlet_id = body.outlet_id ? String(body.outlet_id) : null;
    if (!/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(email) || email.length > 254) throw new Error("Valid email address required.");
    if (!full_name || full_name.length > 120) throw new Error("Name is required (max 120 characters).");
    if (mobile && mobile.length > 30) throw new Error("Mobile number is too long.");
    if (!["outlet", "co_owner", "owner"].includes(role)) throw new Error("Invalid role.");
    if (owner.role === "co_owner" && role !== "outlet") throw new Error("Partnership accounts can create Outlet users only.");
    if (action === "create_outlet_user" && role !== "outlet") throw new Error("This action only creates Outlet users.");
    if (role === "outlet") {
      if (!outlet_id) throw new Error("Choose an outlet for Outlet users.");
      const { data: outlet, error: outletError } = await admin.from("outlets").select("id,is_active").eq("id", outlet_id).maybeSingle();
      if (outletError || !outlet || outlet.is_active !== true) throw new Error("Selected outlet is missing or inactive.");
    }
    if (role !== "outlet" && outlet_id) throw new Error("Only Outlet users can be assigned to an outlet.");
    if (action === "create_outlet_user") {
      const password = String(body.password || "");
      if (password.length < 8 || password.length > 128) throw new Error("Password must be 8 to 128 characters.");
      const { data: created, error: createError } = await admin.auth.admin.createUser({ email, password, email_confirm: true, user_metadata: { full_name } });
      if (createError || !created.user) throw new Error(createError?.message || "Could not create Outlet login.");
      const { error: profileError } = await admin.from("profiles").insert({ id: created.user.id, full_name, mobile, role: "outlet", outlet_id, is_active: true, created_by: authData.user.id });
      if (profileError) {
        await admin.auth.admin.deleteUser(created.user.id);
        throw new Error("Outlet profile creation failed: " + profileError.message);
      }
      return new Response(JSON.stringify({ ok: true, email, message: "Outlet login created." }), { status: 200, headers: cors });
    }
    const { data: invite, error: inviteError } = await admin.auth.admin.generateLink({ type: "invite", email, options: { redirectTo, data: { full_name } } });
    if (inviteError || !invite?.user?.id || !invite?.properties?.action_link) throw new Error(inviteError?.message || "Could not generate invite link. Check Auth settings and whether this email already exists.");
    const { error: profileError } = await admin.from("profiles").insert({ id: invite.user.id, full_name, mobile, role, outlet_id: role === "outlet" ? outlet_id : null, is_active: true, created_by: authData.user.id });
    if (profileError) {
      // Do not delete the Auth user here: generateLink can return an existing user.
      // Deleting that ID could destroy a pre-existing account. Report the error safely.
      throw new Error("Profile creation failed: " + profileError.message + ". No Auth account was deleted; check whether this email already has a profile.");
    }
    return new Response(JSON.stringify({ ok: true, email, invite_url: invite.properties.action_link, message: "Invite link created. Share it securely with the team member; the link is not emailed automatically." }), { status: 200, headers: cors });
  } catch (err) {
    return new Response(JSON.stringify({ error: err instanceof Error ? err.message : "Unexpected error." }), { status: 400, headers: cors });
  }
});
