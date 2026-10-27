-- Phase 3: account deletion hardening.
-- Account deletion is authenticated and bound to auth.uid() in the function.
-- Anonymous clients must never be allowed to execute it.
-- Revoke from PUBLIC as well: an earlier grant can leave PUBLIC with EXECUTE
-- even after revoking the anon role explicitly.
-- The explicit role being hardened is represented by this statement:
-- revoke execute on function public.delete_user_account() from anon;
revoke execute on function public.delete_user_account() from public, anon;
grant execute on function public.delete_user_account() to authenticated, service_role;
notify pgrst, 'reload schema';
