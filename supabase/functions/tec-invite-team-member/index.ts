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
    const { data: owner, error: ownerError } = await admin.from("profiles").select("id,role,is_active").eq("id", authData.user.id).maybeSingle();
    if (ownerError || !owner || owner.role !== "owner" || owner.is_active !== true) {
      return new Response(JSON.stringify({ error: "Only an active Owner can invite team members." }), { status: 403, headers: cors });
    }
    const body = await req.json();
    const action = String(body.action || "invite");
    const redirectTo = "https://tec-masala-business.vercel.app/";
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
    if (action !== "invite") throw new Error("Unsupported action.");
    const email = String(body.email || "").trim().toLowerCase();
    const full_name = String(body.full_name || "").trim();
    const mobile = String(body.mobile || "").trim() || null;
    const role = String(body.role || "");
    const outlet_id = body.outlet_id ? String(body.outlet_id) : null;
    if (!/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(email) || email.length > 254) throw new Error("Valid email address required.");
    if (!full_name || full_name.length > 120) throw new Error("Name is required (max 120 characters).");
    if (mobile && mobile.length > 30) throw new Error("Mobile number is too long.");
    if (!["outlet", "co_owner", "owner"].includes(role)) throw new Error("Invalid role.");
    if (role === "outlet") {
      if (!outlet_id) throw new Error("Choose an outlet for Outlet users.");
      const { data: outlet, error: outletError } = await admin.from("outlets").select("id,is_active").eq("id", outlet_id).maybeSingle();
      if (outletError || !outlet || outlet.is_active !== true) throw new Error("Selected outlet is missing or inactive.");
    }
    if (role !== "outlet" && outlet_id) throw new Error("Only Outlet users can be assigned to an outlet.");
    const { data: invite, error: inviteError } = await admin.auth.admin.generateLink({ type: "invite", email, options: { redirectTo, data: { full_name } } });
    if (inviteError || !invite?.user?.id || !invite?.properties?.action_link) throw new Error(inviteError?.message || "Could not generate invite link. Check Auth settings and whether this email already exists.");
    const { error: profileError } = await admin.from("profiles").insert({ id: invite.user.id, full_name, mobile, role, outlet_id: role === "outlet" ? outlet_id : null, is_active: true });
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